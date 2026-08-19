# iOS 27 本机配对文件获取 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 iOS 27+ 的 StikDebug 内置 pairable host 流程，自动生成并安全保存 RPPairing 配对文件，同时保留旧版手动导入流程。

**Architecture:** 更新与 C 头文件匹配的 idevice FFI 静态库；后台线程调用 `pairable_host_accept`；Network.framework 广播 `_remotepairing-pairable-host._tcp` 并 relay 到 FFI loopback listener；现有 `PairingFileStore` 原子验证并替换文件；SwiftUI 只负责配对向导，不触发 VPN。

**Tech Stack:** Swift / SwiftUI / Network.framework / Foundation / Rust idevice FFI / Swift Testing / Xcode 26 iOS SDK。

## Global Constraints

- iOS 27+ 显示本机配对入口；iOS 18–26 保留手动导入入口。
- 本功能只生成和保存 `rp_pairing_file.plist`，不修改 VPN、LocalDevVPN、`tunnel_create_rppairing` 或模拟定位传输。
- `StikJITTests/StikJITTests.swift` 中用户已有的未提交改动必须保留，禁止重置、覆盖、格式化或加入本功能提交。
- `idevice.h` 与 `libidevice_ffi.a` 必须来自同一个 idevice 构建版本。
- 不记录 PIN、私钥、altIRK 或 pairing 文件内容。
- 只有临时文件写入完成、`rp_pairing_file_read` 验证成功并设置 `0600` 后才替换正式文件。
- 失败、取消、超时或保存失败时，已有配对文件保持不变。
- 配对流程不调用 `StikDebugVPNManager.start()` 或 `ensureReady()`。
- 不添加 Wi-Fi-only 条件，不宣称本阶段解决后续 RPPairing tunnel 的 Wi-Fi 依赖。

---

### Task 1: 更新并验证 pairable-host FFI

**Files:**
- Modify: `StikJIT/idevice/idevice.h`
- Modify: `StikJIT/idevice/libidevice_ffi.a`
- Create: `StikJITTests/PairableHostFFITests.swift`
- Modify: `StikDebug.xcodeproj/project.pbxproj`

**Interfaces:** Produces `PairableHostListeningCallback`, `PairableHostConnectedCallback`, `pairable_host_accept` and preserves existing pairing-file/tunnel symbols.

- [ ] **Step 1: Verify RED.** Run `rg -n -S "pairable_host_accept|PairableHostListeningCallback|PairableHostConnectedCallback" StikJIT\idevice\idevice.h`; expect no declarations.
- [ ] **Step 2: Pin and download matching artifacts.** Run `git ls-remote https://github.com/ChrisMack32/Locus.git refs/heads/main`, save the returned commit SHA in the implementation commit message, then download `Vendor/idevice/idevice.h` and `Vendor/idevice/libidevice_ffi.a` from that same SHA into the two project paths. Never mix revisions or add a declaration to an old library.
- [ ] **Step 3: Verify symbols.** Confirm the header contains `pairable_host_accept`, both callback types, `rp_pairing_file_read/write/free`, and `tunnel_create_rppairing`. On macOS run `lipo -info` and `nm -gU` to confirm an arm64 slice and all symbols.
- [ ] **Step 4: Add the failing smoke test before the production bridge.**

```swift
import Testing
import idevice

struct PairableHostFFITests {
    @Test func bundledFFIExposesPairableHostEntryPoint() {
        let function: Any = pairable_host_accept
        #expect(String(describing: function).isEmpty == false)
    }
}
```

Run the focused Xcode test; it must fail before the FFI update and pass after it.
- [ ] **Step 5: Commit only these explicit paths.** `git add -- StikJIT/idevice/idevice.h StikJIT/idevice/libidevice_ffi.a StikJITTests/PairableHostFFITests.swift StikDebug.xcodeproj/project.pbxproj` then commit `feat: add iOS 27 pairable host FFI`. Do not stage `StikJITTests/StikJITTests.swift`.

---

### Task 2: Add atomic file commit and pure state primitives

**Files:**
- Modify: `StikJIT/Utilities/Extensions.swift`
- Create: `StikJIT/Utilities/PairOnDeviceState.swift`
- Create: `StikJITTests/PairOnDeviceStateTests.swift`
- Modify: `StikDebug.xcodeproj/project.pbxproj`

**Interfaces:** Produces `PairingFileStore.commitGeneratedPairingFile(sourceURL:fileManager:destinationURL:validator:) throws`, `PairingFileStoreError.validationFailed`, and `PairOnDevicePhase`.

- [ ] **Step 1: Write failing tests.** Test that only `advertising`, `deviceConnected`, and `awaitingPIN(String)` are busy; a valid generated file replaces the destination; a validator failure leaves old bytes unchanged. Use a temporary directory and injected validator closure.
- [ ] **Step 2: Run focused tests and verify missing-symbol RED.** Use `xcodebuild -project StikDebug.xcodeproj -scheme StikDebug -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:StikJITTests/PairOnDeviceStateTests test`.
- [ ] **Step 3: Implement the minimal production code.** Add `PairOnDevicePhase` with `idle`, `advertising`, `deviceConnected`, `awaitingPIN(String)`, `succeeded`, and `failed(String)`. Implement `isBusy` for the three active phases. Implement atomic sibling-temp-file write, validator call, `0600` permissions, replacement, and cleanup. The default validator must call `rp_pairing_file_read`, free the handle, and convert errors without logging contents.
- [ ] **Step 4: Run the focused tests and verify GREEN.** Confirm `StikJITTests/StikJITTests.swift` is unchanged.
- [ ] **Step 5: Commit only the new primitives and tests.** Use commit message `feat: add atomic pairing file commit`.

---

### Task 3: Implement Bonjour advertisement and TCP relay

**Files:**
- Create: `StikJIT/Utilities/PairableHostAdvertiser.swift`
- Create: `StikJITTests/PairableHostAdvertiserTests.swift`
- Modify: `StikJIT/Info.plist`
- Modify: `StikDebug.xcodeproj/project.pbxproj`

**Interfaces:** Produces `PairableHostMetadata`, `PairableHostAdvertiser.start(metadata:)`, `stop()`, and testable `hasActiveRelay`.

- [ ] **Step 1: Write failing tests.** Verify all seven FFI metadata values are preserved and a new advertiser has no active relay before and after `stop()`.
- [ ] **Step 2: Run focused tests and verify RED.** Expect missing metadata/advertiser symbols.
- [ ] **Step 3: Implement the relay.** Use `NWParameters.tcp`, `allowLocalEndpointReuse = true`, `includePeerToPeer = true`, service type `_remotepairing-pairable-host._tcp`, TXT keys `name`, `identifier`, `authTag`, `model`, `flags=1`, `ver`, `minVer`; accept one public connection, connect to `127.0.0.1:<ffiPort>`, pump both directions, and cancel both sides on EOF/error. Never publish RPPairing operation port `49152`.
- [ ] **Step 4: Add `_remotepairing-pairable-host._tcp` to `NSBonjourServices`, run tests, and verify GREEN.**
- [ ] **Step 5: Commit with `feat: advertise iOS 27 pairable host`.** Stage only relay, plist, test, and project files.

---

### Task 4: Implement `PairOnDeviceService`

**Files:**
- Create: `StikJIT/Utilities/PairOnDeviceService.swift`
- Create: `StikJITTests/PairOnDeviceServiceTests.swift`
- Modify: `StikDebug.xcodeproj/project.pbxproj`

**Interfaces:** Produces `@MainActor PairOnDeviceService` with published `phase`/`pin` and `start()`, `stop()`, `reset()`.

- [ ] **Step 1: Write failing lifecycle tests.** Cover initial `idle`, duplicate-start protection, failure, and reset without requiring system Settings; use an injected session driver or test-only deterministic state driver.
- [ ] **Step 2: Run focused tests and verify RED.** Expect missing service symbols.
- [ ] **Step 3: Implement the worker and callbacks.** Guard runtime entry points with iOS 27 availability. Run the blocking FFI call on a dedicated thread using the complete signature `pairable_host_accept("StikDebug", "Mac17,7", 0, pinCallback, context, listeningCallback, context, connectedCallback, context, &altIRK, &pairingFile)`. Listening starts the advertiser; connected sets `deviceConnected`; PIN sets `awaitingPIN` without logging. Success writes a sibling temp file, calls `commitGeneratedPairingFile`, frees the handle, and sets `succeeded`. All errors free resources, stop relay, set `failed`, and preserve the old file. Use a generation token so late callbacks cannot mutate a newer session.
- [ ] **Step 4: Run lifecycle tests and verify GREEN.** Simulator tests cover lifecycle only; real pairing is verified on hardware.
- [ ] **Step 5: Commit with `feat: generate pairing files on iOS 27`.** Do not stage the existing user test file.

---

### Task 5: Add the SwiftUI wizard and localization

**Files:**
- Create: `StikJIT/Views/PairOnDeviceView.swift`
- Modify: `StikJIT/Views/SettingsView.swift`
- Modify: `StikJIT/Resources/Localizable.xcstrings`
- Modify: `StikDebug.xcodeproj/project.pbxproj`

**Interfaces:** Consumes service phase/PIN/start/stop/reset; produces an iOS 27-only wizard that retains import and never starts VPN.

- [ ] **Step 1: Implement states.** Show idle, waiting for Settings, device connected, six-digit PIN, success, failure/retry, and exact Developer Mode instructions. Dismissal stops an active session.
- [ ] **Step 2: Add the conditional Settings entry.** Keep “Import Pairing File”; add a NavigationLink to `PairOnDeviceView` inside `if #available(iOS 27.0, *)`. Do not add `.onAppear` auto-start and do not call VPN methods.
- [ ] **Step 3: Add English and Simplified Chinese strings.** Include title, instructions, phase labels, PIN, retry/cancel/success, local-network permission, and Developer Mode path; leave importer strings unchanged.
- [ ] **Step 4: Verify UI wiring.** Run `rg -n -S "PairOnDeviceView|Pair with StikDebug|Get Pairing File on This iPhone|在此 iPhone 上获取配对文件" StikJIT` and build with `xcodebuild -project StikDebug.xcodeproj -scheme StikDebug -destination 'generic/platform=iOS' build CODE_SIGNING_ALLOWED=NO` on macOS.
- [ ] **Step 5: Commit with `feat: add iOS 27 pairing wizard`.**

---

### Task 6: Full verification and physical-device acceptance

**Files:**
- Modify: no files unless a concrete feature wiring defect is found.
- Preserve: `StikJITTests/StikJITTests.swift` exactly as found before this feature.

- [ ] **Step 1: Run `git diff --check`, `git status --short`, and an `rg` scan for `pairable_host_accept`, `_remotepairing-pairable-host._tcp`, `tunnel_create_rppairing`, `.wifi`, and `requiredInterfaceType`. Confirm the new FFI call is isolated to the pairing service and the existing tunnel call remains in `DeviceTransport.swift`.
- [ ] **Step 2: On macOS run `xcodebuild -project StikDebug.xcodeproj -scheme StikDebug -destination 'platform=iOS Simulator,name=iPhone 16' test` and the unsigned generic iOS build. Report pre-existing test failures separately.
- [ ] **Step 3: On a real iOS 27 device, start the new flow, open Settings → Privacy & Security → Developer Mode → Pair with StikDebug, enter the device passcode and PIN, return to StikDebug, and verify `Documents/rp_pairing_file.plist` is readable by `rp_pairing_file_read`.
- [ ] **Step 4: Repeat the pairing-file flow with Wi-Fi disabled and cellular data enabled; test failed retry with an existing file; test duplicate starts; verify old-file preservation and one active listener. This validates file acquisition only, not the later Wi-Fi-dependent tunnel.
- [ ] **Step 5: Stage only verified feature paths for any fix; never stage, reset, amend, or format `StikJITTests/StikJITTests.swift`.

## Completion Checklist

- [ ] Matching arm64 FFI artifacts and exported pairable-host symbols.
- [ ] Atomic file, relay, and service tests pass.
- [ ] Main app build passes.
- [ ] Existing import flow remains available.
- [ ] iOS 27 device creates a readable pairing file without a computer.
- [ ] Failed pairing preserves the old file.
- [ ] No VPN, Wi-Fi transport, or LocalDevVPN behavior changed.
