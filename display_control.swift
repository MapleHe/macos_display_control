// display_control.swift — 命令行断开 / 重连显示器（类似 BetterDisplay 的 Disconnect / Connect）
//
// 编译:  swiftc -O display_control.swift -o display-control
// 用法:
//   display-control list                 实时扫描，列出显示器状态和当前可执行的操作
//   display-control off [ID|builtin]     断开；不带参数时列出"可断开"的显示器供选择
//   display-control on  [ID|all]         重连；不带参数时列出"可重连"的显示器供选择
//
// 设计要点:
// · 每条命令都先实时扫描，只把当前真正可操作的显示器作为选项；
//   只剩一个可用显示器时，不会出现任何可断开的选项。
// · 唯一的改动是私有函数 CGSConfigureDisplayEnabled，范围 .forSession（注销 / 重启后系统复位）。
// · 不需要后台进程：开盖、唤醒时 macOS 会重新检测显示器，被断开的显示器一般会自动回来。
//   没回来时执行 `display-control on all`；完全没有画面时，合盖再开盖，或重启。
// · 被断开的显示器可能从系统列表中彻底消失，所以把本工具断开的 ID 记在一个小文件里，
//   仅用于"重连"时找回它。显示器恢复后记录自动清除，重启前的记录自动作废。

import AppKit
import CoreGraphics
import Foundation

typealias DisplayID = CGDirectDisplayID

struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - 私有 API（唯一会改动显示器的地方）

// 社区逆向得到的声明（displayplacer 等项目使用）:
//   CGError CGSConfigureDisplayEnabled(CGDisplayConfigRef, CGDirectDisplayID, bool)
// 第三个参数以 Int32 传 0/1：无论被调方按 bool 还是 int 读取，结果都一致。
typealias ConfigureEnabledFn = @convention(c) (CGDisplayConfigRef?, DisplayID, Int32) -> Int32

let configureEnabled: ConfigureEnabledFn? = {
    let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT：只查已加载的库
    for name in ["CGSConfigureDisplayEnabled", "SLSConfigureDisplayEnabled"] {
        if let sym = dlsym(rtldDefault, name) { return unsafeBitCast(sym, to: ConfigureEnabledFn.self) }
    }
    return nil
}()

let missingAPI = Failure("当前系统找不到 CGSConfigureDisplayEnabled，无法操作")

func configure(_ id: DisplayID, enabled: Bool) throws {
    guard let fn = configureEnabled else { throw missingAPI }
    var cfg: CGDisplayConfigRef?
    guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else {
        throw Failure("CGBeginDisplayConfiguration 失败")
    }
    let r = fn(cfg, id, enabled ? 1 : 0)
    guard r == CGError.success.rawValue else {
        CGCancelDisplayConfiguration(cfg)
        throw Failure("ConfigureDisplayEnabled(\(id), \(enabled)) 返回 \(r)")
    }
    let done = CGCompleteDisplayConfiguration(cfg, .forSession)
    guard done == .success else { throw Failure("CGCompleteDisplayConfiguration 失败: \(done.rawValue)") }
}

// MARK: - 实时扫描

func displayList(online: Bool) -> [DisplayID] {
    var ids = [DisplayID](repeating: 0, count: 32)
    var count: UInt32 = 0
    let err = online ? CGGetOnlineDisplayList(32, &ids, &count) : CGGetActiveDisplayList(32, &ids, &count)
    return err == .success ? Array(ids.prefix(Int(count))) : []
}

// "已启用"= 活动，或处于镜像组（镜像中的从屏不在 active 列表里，但有画面）
func isEnabled(_ id: DisplayID) -> Bool {
    CGDisplayIsActive(id) != 0 || CGDisplayIsInMirrorSet(id) != 0
}

struct Record: Codable {  // 本工具断开的显示器
    let name: String
    let builtin: Bool
}

struct Scan {
    let active: [DisplayID]
    let online: [DisplayID]
    let names: [DisplayID: String]
    let records: [DisplayID: Record]
}

func scan() -> Scan {
    var names: [DisplayID: String] = [:]
    for screen in NSScreen.screens {
        if let n = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            names[n.uint32Value] = screen.localizedName
        }
    }
    // 已经恢复的显示器不再需要记录（无论是本工具、开盖还是系统恢复的）
    var records = loadRecords()
    let restored = records.keys.filter(isEnabled)
    if !restored.isEmpty {
        restored.forEach { records[$0] = nil }
        try? saveRecords(records)  // 写不进去也无妨：下次扫描会再清理一次
    }
    return Scan(active: displayList(online: false), online: displayList(online: true),
                names: names, records: records)
}

// 可断开：活动、不在镜像组，且断开后至少还剩一个其他未休眠的活动显示器
func offCandidates(_ s: Scan) -> [DisplayID] {
    s.active.filter { id in
        CGDisplayIsInMirrorSet(id) == 0 && s.active.contains { $0 != id && CGDisplayIsAsleep($0) == 0 }
    }
}

// 可重连：在线但未启用（且不是休眠）的显示器 + 本工具断开、尚未恢复的显示器
func onCandidates(_ s: Scan) -> [DisplayID] {
    let disabled = s.online.filter { !isEnabled($0) && CGDisplayIsAsleep($0) == 0 }
    return Set(disabled).union(s.records.keys).sorted()
}

func isBuiltin(_ id: DisplayID, _ s: Scan) -> Bool {
    CGDisplayIsBuiltin(id) != 0 || s.records[id]?.builtin == true
}

func label(_ id: DisplayID, _ s: Scan) -> String {
    let name = s.names[id] ?? s.records[id]?.name ?? "未命名"
    return "[\(id)] \(name)" + (isBuiltin(id, s) ? "（内建）" : "")
}

func status(_ id: DisplayID, _ s: Scan) -> String {
    if isEnabled(id) { return CGDisplayIsInMirrorSet(id) != 0 ? "已连接（镜像）" : "已连接" }
    if !s.online.contains(id) { return "已断开（系统已看不到它，也可能已拔出）" }
    return CGDisplayIsAsleep(id) != 0 ? "休眠" : "已断开"
}

// 等待条件成立，0.5 秒后再复核一次，避免把重新枚举过程中的瞬时状态当成结果
func waitStable(_ cond: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(3)
    while !cond() {
        if Date() > deadline { return false }
        pump(0.1)
    }
    pump(0.5)
    return cond()
}

// 让 RunLoop 处理系统的显示器变更通知；没有事件源时退化为普通休眠
func pump(_ seconds: Double) {
    if CFRunLoopRunInMode(.defaultMode, seconds, false) == .finished { Thread.sleep(forTimeInterval: seconds) }
}

// MARK: - 记录文件

let recordURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/display-control/disabled.json")

func bootDate() -> Date {
    var tv = timeval()
    var size = MemoryLayout<timeval>.size
    sysctlbyname("kern.boottime", &tv, &size, nil, 0)
    return Date(timeIntervalSince1970: Double(tv.tv_sec))
}

// 只认本次开机后写入的记录；读不到或解析失败都按"没有记录"处理（实时扫描才是依据）
func loadRecords() -> [DisplayID: Record] {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: recordURL.path),
          let modified = attrs[.modificationDate] as? Date, modified > bootDate(),
          let data = try? Data(contentsOf: recordURL),
          let records = try? JSONDecoder().decode([DisplayID: Record].self, from: data)
    else { return [:] }
    return records
}

func saveRecords(_ records: [DisplayID: Record]) throws {
    let fm = FileManager.default
    if records.isEmpty {
        if fm.fileExists(atPath: recordURL.path) { try fm.removeItem(at: recordURL) }
        return
    }
    try fm.createDirectory(at: recordURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try JSONEncoder().encode(records).write(to: recordURL, options: .atomic)
}

// MARK: - 选择目标（只能从本次扫描得到的候选中选）

func pick(_ arg: String?, from candidates: [DisplayID], _ s: Scan, verb: String, none: String) throws -> DisplayID {
    guard !candidates.isEmpty else { throw Failure(none) }
    let options = candidates.map { label($0, s) }.joined(separator: "、")

    if let arg {
        let id: DisplayID? = arg == "builtin" ? candidates.first(where: { isBuiltin($0, s) }) : DisplayID(arg)
        guard let id, candidates.contains(id) else { throw Failure("\(arg) 当前不能\(verb)。可选: \(options)") }
        return id
    }

    print("可\(verb)的显示器:")
    for (i, id) in candidates.enumerated() { print("  \(i + 1). \(label(id, s))  \(status(id, s))") }
    print("输入序号（直接回车取消）: ", terminator: "")
    fflush(stdout)
    guard let line = readLine(), let n = Int(line.trimmingCharacters(in: .whitespaces)),
          candidates.indices.contains(n - 1) else { throw Failure("已取消") }
    return candidates[n - 1]
}

// MARK: - 命令

func cmdList() {
    let s = scan()
    print("显示器（实时扫描）:")
    for id in Set(s.online).union(s.records.keys).sorted() {
        var line = "  \(label(id, s))  \(status(id, s))"
        if CGDisplayIsActive(id) != 0 {
            line += "  \(CGDisplayPixelsWide(id))x\(CGDisplayPixelsHigh(id))"
            if CGDisplayIsMain(id) != 0 { line += "  主显示器" }
        }
        print(line)
    }
    let off = offCandidates(s).map { String($0) }, on = onCandidates(s).map { String($0) }
    print("可断开: " + (off.isEmpty ? "无（至少保留一个可用显示器）" : off.joined(separator: ", ")))
    print("可重连: " + (on.isEmpty ? "无" : on.joined(separator: ", ")))
}

func cmdOff(_ arg: String?) throws {
    let first = scan()
    let target = try pick(arg, from: offCandidates(first), first, verb: "断开",
                          none: "只剩一个可用显示器（镜像、休眠的不算），不能断开")

    // 交互选择期间情况可能已变：提交前重新扫描确认
    let s = scan()
    guard offCandidates(s).contains(target) else { throw Failure("显示器状态已变化，请重新执行") }
    if CGDisplayIsMain(target) != 0 { print("注意: 目标是主显示器，菜单栏会移到其他显示器") }

    // 先记录再断开；记录写不进去就不动显示器
    var records = s.records
    records[target] = Record(name: s.names[target] ?? "未命名", builtin: isBuiltin(target, s))
    try saveRecords(records)

    var configError: Error?
    do { try configure(target, enabled: false) } catch { configError = error }

    // 以实际状态为准：目标已断开，并且仍有其他未休眠的活动显示器
    let gone = waitStable { !isEnabled(target) }
    let othersOK = displayList(online: false).contains { $0 != target && CGDisplayIsAsleep($0) == 0 }
    if gone && othersOK {
        print("已断开 \(label(target, s))")
        return
    }

    // 失败：尽量恢复原状（残留记录会在下次扫描时自动清理）
    if !isEnabled(target) {
        try? configure(target, enabled: true)
        _ = waitStable { isEnabled(target) }
    }
    let reason = gone ? "断开后没有其他可用显示器" : "断开未生效" + (configError.map { "（\($0)）" } ?? "")
    throw Failure(reason + (isEnabled(target) ? "，已恢复原状" : "，且未能自动恢复：请合盖再开盖，或重启"))
}

func cmdOn(_ arg: String?) throws {
    let s = scan()
    let candidates = onCandidates(s)
    let targets: [DisplayID]
    if arg == "all" {
        guard !candidates.isEmpty else { print("没有需要重连的显示器"); return }
        targets = candidates
    } else {
        targets = try [pick(arg, from: candidates, s, verb: "重连", none: "没有需要重连的显示器")]
    }

    var failed: [String] = []
    for id in targets {
        do { try configure(id, enabled: true) } catch { print("警告: \(error)") }
        if waitStable({ isEnabled(id) }) { print("已重连 \(label(id, s))") } else { failed.append(label(id, s)) }
    }
    // 成功的记录无需手动删除：下次扫描时自动清理
    if !failed.isEmpty {
        throw Failure("未能重连 \(failed.joined(separator: "、"))。可尝试合盖再开盖、重新插拔，或注销 / 重启")
    }
}

// MARK: - 入口

let usage = """
用法:
  display-control list                 列出显示器状态
  display-control off [ID|builtin]     断开（不带参数则交互选择）
  display-control on  [ID|all]         重连（不带参数则交互选择）
"""

guard getuid() != 0 else {
    print("请以当前登录用户运行，不要使用 sudo")
    exit(1)
}

let args = Array(CommandLine.arguments.dropFirst())
let argTarget = args.count == 2 ? args[1] : nil
do {
    switch (args.first ?? "list", args.count) {
    case ("list", 0...1): cmdList()
    case ("off", 1...2):  guard configureEnabled != nil else { throw missingAPI }; try cmdOff(argTarget)
    case ("on", 1...2):   guard configureEnabled != nil else { throw missingAPI }; try cmdOn(argTarget)
    default:              print(usage); exit(2)
    }
} catch {
    print("错误: \(error)")
    exit(1)
}
