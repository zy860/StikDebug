# iOS 27 本机配对文件获取设计

## 状态

已确认设计，待实现计划。

## 目标

为 StikDebug 增加 iOS 27+ 本机获取 RPPairing 配对文件的功能，使用户不再依赖电脑或 `idevice_pair` 生成初始配对文件，同时保留现有的手动导入方式以兼容 iOS 18–26 和异常场景。

本功能只负责配对关系建立和 `rp_pairing_file.plist` 保存，不改变当前 VPN、LocalDevVPN、RPPairing tunnel、JIT 或模拟定位传输逻辑。

## 背景与依据

iOS 27 支持设备主动连接一个通过 Bonjour 广播的 pairable host 服务。服务类型为 `_remotepairing-pairable-host._tcp`，配对过程中由 host 侧显示 6 位 PIN，完成后生成 RPPairing 文件。

Locus 是目前可参考的完整开源实现：

- [Locus README](https://github.com/ChrisMack32/Locus)
- [PairOnDeviceService.swift](https://raw.githubusercontent.com/ChrisMack32/Locus/main/Locus/Engine/PairOnDeviceService.swift)
- [PairableHostAdvertiser.swift](https://raw.githubusercontent.com/ChrisMack32/Locus/main/Locus/Engine/PairableHostAdvertiser.swift)
- [idevice pairable host FFI](https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/pairable_host.rs)

当前 StikDebug 已有 `PairingFileStore` 和 RPPairing 文件读写 API，但当前 bundled `idevice.h` 和 `libidevice_ffi.a` 没有 `pairable_host_accept` 及其回调类型。因此头文件和静态库必须同步升级，不能只在 Swift 工程中手写函数声明。

## 范围

### 包含

- 更新 bundled idevice FFI 到包含 iOS 27 pairable-host API 的版本。
- 在 App 内启动一次性的本机配对服务。
- 通过 `NWListener` 广播 `_remotepairing-pairable-host._tcp`。
- 将系统连接双向 relay 到 Rust FFI 的 loopback listener。
- 显示配对状态和 6 位 PIN。
- 将生成的文件安全地保存为现有 `PairingFileStore` 使用的文件。
- iOS 27+ 显示本机配对入口。
- iOS 18–26 保留现有导入入口。
- 配对失败、取消或保存失败时保留已有配对文件。

### 不包含

- 不替换当前 `tunnel_create_rppairing` 传输流程。
- 不修改 `DeviceTransport.swift` 的 VPN 启动和目标端口逻辑。
- 不修改 `StikDebugTunnel/PacketTunnelProvider.swift`。
- 不自动启动或停止 VPN。
- 不移除 Wi-Fi 检查或 LocalDevVPN 相关传输依赖。
- 不实现新的蜂窝网络 RPPairing tunnel。

## 架构

### 1. FFI 层

`StikJIT/idevice/idevice.h` 和 `StikJIT/idevice/libidevice_ffi.a` 必须来自同一个构建版本，并共同提供以下能力：

- `PairableHostListeningCallback`
- `PairableHostConnectedCallback`
- `pairable_host_accept(...)`
- `rp_pairing_file_write(...)`
- `rp_pairing_file_free(...)`
- `idevice_error_free(...)`

`pairable_host_accept` 的 Swift 调用需要覆盖完整参数，包括监听回调、连接回调、PIN 回调、host altIRK 输出和 pairing file 输出。不得向旧静态库添加不存在的函数声明。

FFI 更新后必须保留当前项目使用的既有符号。构建验证需要检查 arm64 iOS 静态库能够同时解析新旧 API。

### 2. PairOnDeviceService

新增一个只负责生命周期和状态转发的服务对象，建议接口如下：

```swift
@MainActor
final class PairOnDeviceService: ObservableObject {
    enum Phase: Equatable {
        case idle
        case advertising
        case deviceConnected
        case awaitingPIN(String)
        case succeeded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var pin: String?

    func start()
    func stop()
    func reset()
}
```

实现要求：

- `start()` 只能同时启动一个配对会话。
- 阻塞的 FFI 调用必须运行在专用后台线程，不得阻塞主线程或 SwiftUI 渲染线程。
- FFI 回调只传递不可变的字符串、数值或状态，不直接操作 SwiftUI。
- 回调通过 `DispatchQueue.main` 或 MainActor 更新状态。
- 通过 callback box 保持服务弱引用，避免 FFI 线程意外延长 View 生命周期。
- PIN 不写入普通日志，不记录 pairing 文件内容。
- 成功后释放 pairing file handle；错误后释放 FFI error。
- 配对会话结束后停止 Bonjour listener、relay 和 keep-alive 资源。

当前 FFI 接口没有通用取消句柄，因此 `stop()` 的保证范围是：立即停止公开 listener/relay、阻止新会话、标记当前会话失效并释放 UI/后台资源；如果底层 accept 仍在等待，迟到的回调必须通过会话 generation token 丢弃，不能覆盖后续会话状态。

### 3. PairableHostAdvertiser 与 Relay

新增 Network.framework relay 对象：

- 使用 `NWListener(using: .tcp)`。
- 发布服务类型 `_remotepairing-pairable-host._tcp`。
- TXT record 使用 FFI listening callback 提供的 `name`、`identifier`、`authTag`、`model`、`ver` 和 `minVer`。
- 设置 `includePeerToPeer = true` 和端口复用。
- 收到系统连接后，只允许一个 active relay。
- 通过 `NWConnection` 连接 `127.0.0.1:<ffiPort>`。
- 双向泵送 TCP 数据，任一侧失败或关闭时取消另一侧。
- `stop()` 必须取消 listener、active relay 和所有连接。

`StikJIT/Info.plist` 增加 `_remotepairing-pairable-host._tcp` 到 `NSBonjourServices`。项目已有本地网络使用说明，不新增 Wi-Fi 强制条件；系统显示的本地网络权限错误需要单独处理。

### 4. PairingFileStore

继续使用现有路径：

```text
Documents/rp_pairing_file.plist
```

新增原子保存流程：

1. 在同一目录创建随机临时文件。
2. 由 FFI 将 pairing file 写入临时文件。
3. 读取临时文件并调用 `rp_pairing_file_read` 验证格式。
4. 设置 POSIX 权限 `0600`。
5. 使用同目录替换方式原子替换正式文件。
6. 清理临时文件。

任何一步失败，都不删除或覆盖原有 pairing 文件。

### 5. SwiftUI 设置入口

在“配对文件”分区中增加 iOS 27 条件入口：

```swift
if #available(iOS 27.0, *) {
    Button("Get Pairing File on This iPhone") { ... }
}
```

入口打开配对向导，向用户说明：

1. 点击开始配对并保持 StikDebug 不被强制退出。
2. 打开“设置 → 隐私与安全性 → 开发者模式”。
3. 选择“Pair with StikDebug”并点击 Pair。
4. 输入设备密码。
5. 将 StikDebug 显示的 6 位 PIN 输入系统。
6. 返回 StikDebug 等待保存完成。

按钮在 `advertising`、`deviceConnected`、`awaitingPIN` 阶段禁用；失败时提供“重试”；成功时显示已保存，并保留现有“导入配对文件”入口。

该向导不调用 `StikDebugVPNManager.start()` 或 `ensureReady()`。

## 状态与错误处理

### 状态转换

```text
idle
  └─ start → advertising
                   ├─ device connected → deviceConnected
                   │                         └─ PIN callback → awaitingPIN(pin)
                   │                                             └─ success → succeeded
                   └─ listener/FFI/error → failed(message)

failed ── retry → advertising
succeeded ── done/reset → idle
任何活动状态 ── stop → idle（迟到回调被忽略）
```

### 错误分类

- iOS 版本不支持：入口不显示，不进入服务层。
- 本地网络权限拒绝：提示到系统设置开启本地网络。
- Bonjour listener 失败：提示服务无法发布，并记录底层错误描述。
- 系统未发现服务：提示重新打开开发者模式并保持 App 活跃。
- FFI 接受/握手失败：显示 FFI 返回的错误，不删除旧文件。
- 配对超时：停止当前会话并允许重试。
- 写入或验证失败：显示保存失败，保留旧文件。
- 用户离开或强制退出：下次打开后状态回到 idle，旧文件不变。

## 测试与验收

### 单元测试

放在 `StikJITTests/StikJITTests.swift` 或新的配对测试文件中，覆盖：

- iOS 版本能力判断。
- 状态机的合法转换和重复启动保护。
- 失败状态可重试。
- 临时文件写入后验证成功才替换正式文件。
- 新文件无效时旧文件保持不变。
- 写入失败时旧文件保持不变。
- FFI 错误转换为用户可读错误。
- stop 后 active relay/listener 状态清理。
- 现有导入流程的路径和权限行为不变。

### 静态构建验证

- `idevice.h` 声明与 `libidevice_ffi.a` 导出的 `pairable_host_accept` 签名一致。
- FFI 静态库包含 arm64 iOS slice。
- 项目仅将配对服务源文件加入主 App target。
- `NSBonjourServices` 含 `_remotepairing-pairable-host._tcp`。
- 现有 VPN extension target 和配置没有变化。
- 运行 `git diff --check`。

### 真机验收

在 iOS 27 真机上验证：

1. 配对文件不存在时能启动本机配对。
2. 系统开发者模式能发现 `Pair with StikDebug`。
3. 设备密码和 6 位 PIN 流程可完成。
4. App 自动生成并保存 `rp_pairing_file.plist`。
5. 返回设置页后显示已保存。
6. 重新打开 App 后配对文件仍存在且能被 `rp_pairing_file_read` 读取。
7. 配对过程中关闭 Wi-Fi，仅使用蜂窝网络，仍能完成“配对文件获取”验证。
8. 配对失败时原有 pairing 文件不被删除。
9. 重试不会产生多个 listener 或多个后台 FFI 会话。
10. iOS 18–26 设备仍可使用原有导入入口。

这里的蜂窝网络验收只针对配对文件获取，不代表当前后续 RPPairing tunnel 已经脱离 Wi-Fi。

## 安全与隐私

- pairing 文件包含长期密钥，只保存在 App 沙盒 Documents 目录。
- 文件权限设置为 `0600`。
- PIN、密钥和 pairing 文件内容不写入日志、不上传网络。
- 失败时不把临时文件或部分文件留在正式路径。
- 不通过新的外部 App 或远程服务器传输配对数据。

## 参考实现

- [Locus README](https://github.com/ChrisMack32/Locus)
- [Locus PairOnDeviceService.swift](https://raw.githubusercontent.com/ChrisMack32/Locus/main/Locus/Engine/PairOnDeviceService.swift)
- [Locus PairableHostAdvertiser.swift](https://raw.githubusercontent.com/ChrisMack32/Locus/main/Locus/Engine/PairableHostAdvertiser.swift)
- [idevice pairable_host.rs](https://raw.githubusercontent.com/jkcoxson/idevice/master/ffi/src/pairable_host.rs)
- [Apple NEPacketTunnelProvider](https://developer.apple.com/documentation/networkextension/nepackettunnelprovider)
