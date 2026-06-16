//
//  Converter.swift
//  CertFlow
//
//  Created by GAO on 2026/6/15.
//

import Foundation

// 定义一个结构体来管理每个文件的状态
struct P12FileItem: Identifiable {
    let id = UUID()
    let path: String
    var password: String = ""
    var status: ConversionStatus = .pending
    var logMessage: String = "等待转换..."
    var certMeta: String = ""
    var networkStatus: String = ""
    
    var fileName: String {
        return URL(fileURLWithPath: path).lastPathComponent
    }
}

enum ConversionStatus {
    case pending   // 等待
    case converting// 转换中
    case success   // 成功
    case failed    // 失败
}

enum APNsEnvironment {
    case development
    case production
    case unknown
}

// 解析结果的结构体
struct CertParseResult {
    let environment: APNsEnvironment
    let metaText: String
}

class Converter {
    
    // 寻找 openssl 路径
    private static func findOpenSSLPath() -> String {
        let paths = [
            "/opt/homebrew/bin/openssl", // Apple Silicon Homebrew
            "/usr/local/bin/openssl",    // Intel Homebrew
            "/usr/bin/openssl"           // macOS 自带
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) { return path }
        }
        return "/usr/bin/openssl"
    }
    
    // 动态嗅探内核是否需要 legacy
    private static func checkNeedsLegacy(path: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["version"]
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        
        try? process.run()
        process.waitUntilExit()
        
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let versionStr = String(data: data, encoding: .utf8) ?? ""
        return versionStr.contains("OpenSSL 3.")
    }
    
    // MARK: - 核心转换与验证方法
    static func convertAndVerify(item: P12FileItem, completion: @escaping (ConversionStatus, String, String, String) -> Void) {
        let fileURL = URL(fileURLWithPath: item.path)
        let directory = fileURL.deletingLastPathComponent().path
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        let outputPemPath = "\(directory)/\(baseName).pem"
        
        let opensslPath = findOpenSSLPath()
        let needsLegacy = checkNeedsLegacy(path: opensslPath)
        
        var args = ["pkcs12", "-in", item.path, "-out", outputPemPath, "-nodes", "-passin", "pass:\(item.password)"]
        if needsLegacy { args.insert("-legacy", at: 1) }
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opensslPath)
        process.arguments = args
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                // 1. 获取本地静态结构化解析结果
                let parseResult = verifyCertDetails(opensslPath: opensslPath, pemPath: outputPemPath)
                
                // 2. 严格的类型分支判定（告别字符串模糊匹配）
                let isProduction = (parseResult.environment == .production)
                
                // 3. 异步启动网络动态握手验证
                completion(.success, "\(outputPemPath)", parseResult.metaText, "🌐 正在联网验证 APNs...")
                
                DispatchQueue.global(qos: .userInitiated).async {
                    let netResult = testAPNsConnection(opensslPath: opensslPath, pemPath: outputPemPath, isProduction: isProduction)
                    DispatchQueue.main.async {
                        completion(.success, "\(outputPemPath)", parseResult.metaText, netResult)
                    }
                }
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "未知错误"
                if errorString.lowercased().contains("mac verify error") || errorString.lowercased().contains("password") {
                    completion(.failed, "❌ 密码错误", "", "")
                } else {
                    completion(.failed, "❌ \(errorString.trimmingCharacters(in: .whitespacesAndNewlines))", "", "")
                }
            }
        } catch {
            completion(.failed, "💥 运行失败: \(error.localizedDescription)", "", "")
        }
    }
    
    // MARK: - 验证证书详情的方法
    private static func verifyCertDetails(opensslPath: String, pemPath: String) -> CertParseResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opensslPath)
        // 同时读取主题和有效期
        process.arguments = ["x509", "-in", pemPath, "-noout", "-subject", "-enddate"]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        try? process.run()
        process.waitUntilExit()
        
        let rawOutput = String(data: outputPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        
        // 1. 严格基于苹果官方原始英文标识符判定环境
        var env: APNsEnvironment = .unknown
        var envText = "未知环境"
        
        // 必须先判断更长的“Development”字符串，防止被短的“Apple Push Services”拦截
        if rawOutput.contains("Apple Development IOS Push Services") {
            env = .development
            envText = "开发"
        } else if rawOutput.contains("Apple Push Services") {
            env = .production
            envText = "生产/通用"
        }
        
        // 2. 提取过期时间 (逻辑保持不变)
        var expiryStatus = "未知时间"
        let lines = rawOutput.components(separatedBy: .newlines)
        if let dateLine = lines.first(where: { $0.contains("notAfter=") }) {
            let rawDateStr = dateLine.replacingOccurrences(of: "notAfter=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(abbreviation: "GMT")
            if let expiryDate = formatter.date(from: rawDateStr) {
                let components = Calendar.current.dateComponents([.day], from: Date(), to: expiryDate)
                if let daysLeft = components.day {
                    if daysLeft < 0 { expiryStatus = "❌已过期 \(abs(daysLeft))天" }
                    else if daysLeft <= 30 { expiryStatus = "⚠️仅剩 \(daysLeft)天" }
                    else { expiryStatus = "📅剩 \(daysLeft)天" }
                }
            }
        }
        
        return CertParseResult(
            environment: env,
            metaText: "环境: \(env == .production ? "🟢" : "🟡")\(envText) | \(expiryStatus)"
        )
    }
    
    // 文本解析：提取环境和到期时间
    private static func parseOpenSSLText(_ text: String) -> String {
        var env = "未知环境"
        var expiryStatus = "未知时间"
        
        // 1. 判定环境
        if text.contains("Apple Push Services") {
            env = "🟢 生产/通用环境 (Production/Universal)"
        } else if text.contains("Apple Sandbox Push Services") {
            env = "🟡 开发环境 (Sandbox/Development)"
        }
        
        // 2. 提取过期时间 (notAfter=...)
        let lines = text.components(separatedBy: .newlines)
        if let dateLine = lines.first(where: { $0.contains("notAfter=") }) {
            let rawDateStr = dateLine.replacingOccurrences(of: "notAfter=", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
            
            // 创建 OpenSSL 标准 GMT 时间格式解析器
            let formatter = DateFormatter()
            formatter.dateFormat = "MMM d HH:mm:ss yyyy zzz"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(abbreviation: "GMT")
            
            if let expiryDate = formatter.date(from: rawDateStr) {
                let currentDate = Date() // 获取当前时间 (2026年)
                
                // 计算时间差
                let calendar = Calendar.current
                let components = calendar.dateComponents([.day], from: currentDate, to: expiryDate)
                
                if let daysLeft = components.day {
                    if daysLeft < 0 {
                        expiryStatus = "❌ 已过期 \(abs(daysLeft)) 天"
                    } else if daysLeft == 0 {
                        expiryStatus = "🚨 今天即将过期！"
                    } else if daysLeft <= 30 {
                        expiryStatus = "⚠️ 临期！仅剩 \(daysLeft) 天"
                    } else {
                        expiryStatus = "📅 剩 \(daysLeft) 天"
                    }
                }
            } else {
                // 如果特殊系统返回了其他格式，退化显示原始字符串
                expiryStatus = rawDateStr
            }
        }
        
        return "环境: \(env) | 有效期至: \(expiryStatus)"
    }
    
    // MARK: - 联网通道测试核心函数
    private static func testAPNsConnection(opensslPath: String, pemPath: String, isProduction: Bool) -> String {
        let host = isProduction ? "api.push.apple.com:443" : "api.sandbox.push.apple.com:443"
        
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opensslPath)
        // 使用 s_client 连接，-quiet 参数可以精简输出，避免陷入交互模式
        process.arguments = ["s_client", "-connect", host, "-cert", pemPath, "-key", pemPath, "-quiet"]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe
        
        // 关键设置：输入流给一个空的 Pipe，模拟用户敲回车或者断开，防止 openssl s_client 阻塞进程死锁
        process.standardInput = Pipe()
        
        do {
            try process.run()
            
            // 给网络连接最多 5 秒超时时间，防止因用户没网导致卡死
            let timeout: TimeInterval = 5.0
            let start = Date()
            while process.isRunning && Date().timeIntervalSince(start) < timeout {
                Thread.sleep(forTimeInterval: 0.2)
            }
            
            if process.isRunning {
                process.terminate() // 超时强杀
                return "⚡️ 联网验证：超时 (网络不通或收不到握手)"
            }
            
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            
            // 判定分析
            if output.lowercased().contains("verify return code: 0") || output.contains("return code: 0") || output.contains("handshake") == false {
                return "🟢 联网验证：APNs 通道握手成功！证书完全可用"
            } else if output.lowercasedContains("handshake failure") {
                return "🔴 联网验证：苹果服务器拒绝握手 (环境不匹配或证书已被吊销)"
            } else {
                return "⚠️ 联网验证：\(output.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))..."
            }
        } catch {
            return "❌ 联网验证：无法发起连接 (\(error.localizedDescription))"
        }
    }
}

extension String {
    func lowercasedContains(_ string: String) -> Bool {
        return self.lowercased().contains(string.lowercased())
    }
}

// 仅支持单个文件
/*
class Converter {
    static func runP12ToPem(p12Path: String, password: String, completion: @escaping (Bool, String) -> Void) {
        let fileURL = URL(fileURLWithPath: p12Path)
        let directory = fileURL.deletingLastPathComponent().path
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        
        // 输出的 PEM 文件路径，默认和 P12 在同一个文件夹下
        let outputPemPath = "\(directory)/\(baseName).pem"
        
        // 1. 寻找最佳的 openssl 可执行文件路径
        let opensslPath = findOpenSSLPath()
        
        // 2. 检查这个路径下的 openssl 是否支持/需要 -legacy
        let checkResult = checkOpenSSLType(path: opensslPath)
        
        print("🔍 检测到 OpenSSL 路径: \(opensslPath)")
        print("📊 内核版本判定: \(checkResult.versionDescription), 是否使用 legacy: \(checkResult.needsLegacy)")
        
        // 3. 构建精准的参数列表
        var args = ["pkcs12", "-in", p12Path, "-out", outputPemPath, "-nodes", "-passin", "pass:\(password)"]
        if checkResult.needsLegacy {
            args.insert("-legacy", at: 1)
        }
        
        // 4. 执行转换
        let process = Process()
        process.executableURL = URL(fileURLWithPath: opensslPath)
        process.arguments = args
        
        let errorPipe = Pipe()
        process.standardError = errorPipe
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let modeText = checkResult.needsLegacy ? " (Legacy 模式)" : " (Standard 模式)"
                completion(true, "🎉 转换成功\(modeText)！\n文件已保存至：\n\(outputPemPath)")
            } else {
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "未知错误"
                
                if errorString.lowercased().contains("mac verify error") || errorString.lowercased().contains("password") {
                    completion(false, "❌ 转换失败：P12 密码错误！")
                } else {
                    completion(false, "❌ 转换失败：\(errorString)")
                }
            }
        } catch {
            completion(false, "💥 进程运行失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 辅助方法：寻找路径
    private static func findOpenSSLPath() -> String {
        let paths = [
            "/opt/homebrew/bin/openssl", // Apple Silicon Homebrew
            "/usr/local/bin/openssl",    // Intel Homebrew
            "/usr/bin/openssl"           // macOS 自带
        ]
        for path in paths {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return "/usr/bin/openssl"
    }
    
    // MARK: - 辅助方法：版本判定结构体
    private struct OpenSSLCheckResult {
        let needsLegacy: Bool
        let versionDescription: String
    }
    
    // MARK: - 辅助方法：动态嗅探内核
    private static func checkOpenSSLType(path: String) -> OpenSSLCheckResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["version"]
        
        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe // 有些版本把 version 输错到 stderr
        
        do {
            try process.run()
            process.waitUntilExit()
            
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let versionStr = String(data: data, encoding: .utf8) ?? ""
            
            // 判定逻辑
            if versionStr.contains("LibreSSL") {
                return OpenSSLCheckResult(needsLegacy: false, versionDescription: "LibreSSL (无需 legacy)")
            } else if versionStr.contains("OpenSSL 3.") {
                return OpenSSLCheckResult(needsLegacy: true, versionDescription: "OpenSSL 3.x (必须 legacy)")
            } else if versionStr.contains("OpenSSL 1.1") {
                return OpenSSLCheckResult(needsLegacy: false, versionDescription: "OpenSSL 1.1.x (无需 legacy)")
            } else {
                // 无法识别的未知版本，保守起见默认不加
                return OpenSSLCheckResult(needsLegacy: false, versionDescription: "未知内核: \(versionStr.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch {
            // 如果连 version 命令都崩了，兜底不加
            return OpenSSLCheckResult(needsLegacy: false, versionDescription: "检测失败 (兜底 Standard)")
        }
    }
}
*/
