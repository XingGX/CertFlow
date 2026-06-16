# 🔐 CertFlow

一款面向 iOS / macOS 开发的 macOS 原生证书工具，专注解决 `.p12` 证书在 APNs（Apple Push Notification service）通道下的**转换 → 本地校验 → 联网握手验证**一站式工作流。

> 基于 SwiftUI 构建，开箱即用，零外部依赖。

---

## ✨ 核心特性

- **批量转换**：支持一次拖入 / 选择多个 `.p12` 文件，批量转 `.pem`
- **智能 OpenSSL 适配**：
  - 自动探测 `openssl` 路径（Apple Silicon / Intel Homebrew / 系统自带）
  - 自动嗅探 OpenSSL 内核版本（1.1.x / 3.x / LibreSSL）
  - OpenSSL 3.x 自动追加 `-legacy` 参数，兼容旧版 `.p12`
- **本地结构化校验**：解析 `x509 -subject -enddate` 输出，严格识别
  - Apple Development IOS Push Services → 开发环境
  - Apple Push Services → 生产 / 通用环境
  - 自动计算证书剩余有效天数（临期、过期分级提示）
- **联网握手验证**：调用 `openssl s_client` 真实连接 APNs
  - `api.push.apple.com:443`（生产）
  - `api.sandbox.push.apple.com:443`（开发）
  - 5 秒超时保护，避免无网场景下进程卡死
  - 识别 `handshake failure` 等典型错误并精准提示
- **友好交互**：
  - 全局密码一键批量填充
  - 触控板双指左滑删除
  - 失败错误日志横向滚动 + 可划选复制
  - ⌘ Command + 点击路径直达 Finder 高亮

---

## 📸 界面预览

> 应用启动后呈现拖拽区；导入文件后展示文件列表 + 批量密码栏 + 底部启动按钮。

| 空状态 | 导入后 |
| :---: | :---: |
| 虚线拖拽大框 | 文件行 + 状态徽标 + 操作栏 |

---

## 🛠 系统要求

| 项目 | 要求 |
| :--- | :--- |
| 操作系统 | macOS 13.0 (Ventura) 及以上 |
| Xcode | 15.0 及以上 |
| Swift | 5.9 及以上 |
| 外部依赖 | `openssl`（建议 Homebrew 安装） |

> 应用依赖系统中的 `openssl` 可执行文件。推荐：
> ```bash
> brew install openssl
> ```

---

## 🚀 构建与运行

1. 克隆仓库
   ```bash
   git clone <repo-url>
   cd CertFlow
   ```
2. 用 Xcode 打开 `CertFlow.xcodeproj`
3. 选择 `CertFlow` scheme，⌘R 运行

> 首次运行若提示无法访问 `openssl`，请在「系统设置 → 隐私与安全性」中放行。

---

## 📖 使用说明

### 单文件 / 多文件导入

- **拖拽**：将 `.p12` 文件直接拖入窗口
- **点选**：点击「选择文件 (可多选)」按钮

### 批量密码

顶部输入密码后，自动同步至所有文件行；亦可在每行单独覆盖。

### 启动转换

点击底部「开始转换」，每个文件将依次经历：
```
p12 → pem (openssl pkcs12)
      ↓
   本地解析 (openssl x509) → 环境 / 有效期
      ↓
   联网握手 (openssl s_client) → 5s 超时
      ↓
   状态写回 UI
```

### 状态说明

| 状态 | 含义 |
| :--- | :--- |
| `pending` | 等待转换 |
| `converting` | 转换中 |
| `success` | 本地 + 联网均通过 |
| `failed` | 密码错 / 证书过期 / 握手失败等 |

---

## 🏗 项目结构

```
CertFlow/
├── CertFlow/                  # 主工程源码
│   ├── CertFlowApp.swift      # @main 入口
│   ├── ContentView.swift      # SwiftUI 主界面 + 交互逻辑
│   ├── Converter.swift        # 核心转换 / 校验 / 联网逻辑
│   └── Assets.xcassets/       # 图标与配色资源
├── CertFlowTests/             # 单元测试
├── CertFlowUITests/           # UI 测试
├── CertFlow.xcodeproj/        # Xcode 工程文件
└── .gitignore
```

### 关键模块

- **`Converter`**：负责 `openssl` 进程编排、错误分类、APNs 握手
- **`P12FileItem`**：单个文件的状态模型（路径 / 密码 / 状态 / 日志）
- **`ContentView`** + **`FileRowView`**：SwiftUI 视图层，承载拖拽 / 列表 / 状态徽标

---

## 🔍 技术决策

- **进程模型**：使用 `Foundation.Process` + `Pipe` 直接驱动 `openssl`，避免引入 OpenSSL 的 Swift 封装（减小包体、避免证书链信任配置差异）
- **解析策略**：所有 `OpenSSL` 文本输出走自定义 `String.lowercasedContains` 扩展做大小写不敏感匹配，规避 locale 影响
- **环境判定优先**：先匹配 `Apple Development IOS Push Services`（更长串），再匹配 `Apple Push Services`，避免误判
- **超时保护**：APNs 联网握手走 `while process.isRunning && elapsed < 5s` 自旋 + `Thread.sleep(0.2)`，保证主线程不卡顿

---

## 🧪 测试

```bash
# 单元测试
xcodebuild test -scheme CertFlow -destination 'platform=macOS'

# UI 测试
xcodebuild test -scheme CertFlowUITests -destination 'platform=macOS'
```

---

## 🗺 Roadmap

- [ ] 导出 `.mobileprovision` 关联校验
- [ ] Apple Push Certificate 状态联动（过期前 N 天自动提醒）
- [ ] 自定义 APNs 主机 / 端口（应对企业内网代理场景）
- [ ] 命令行模式（脱离 GUI 触发）

---

## 🤝 贡献

欢迎 Issue / PR。请保持提交粒度小、信息密度高，并附上可复现步骤。

---

## 📄 许可

MIT License

---

Create by GAO · 2026
