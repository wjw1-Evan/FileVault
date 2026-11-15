#!/usr/bin/env swift
//
// issue-license.swift — 发行方签发 FileVault 授权码（不随应用分发）。
//
// 用法：
//   swift scripts/issue-license.swift --key ~/.filevault/license-signing-key \
//       --id lic_001 --email user@example.com --plan pro --issued 2026-11-15
//
// 私钥文件内容为 Ed25519 原始私钥的 base64（32 字节，单行）。
// 生成的令牌形如 fv1.<payload>.<signature>，用户在「设置 → 许可与支持」粘贴激活。
//
import Foundation
import CryptoKit

struct License: Codable {
    var v: Int
    var id: String
    var email: String
    var plan: String
    var issuedAt: String
    var expiresAt: String?
}

func die(_ message: String) -> Never {
    FileHandle.standardError.write(("错误：" + message + "\n").data(using: .utf8)!)
    exit(1)
}

func b64url(_ data: Data) -> String {
    data.base64EncodedString()
        .replacingOccurrences(of: "+", with: "-")
        .replacingOccurrences(of: "/", with: "_")
        .replacingOccurrences(of: "=", with: "")
}

var args: [String: String] = [:]
var i = 1
let argv = CommandLine.arguments
while i < argv.count {
    let key = argv[i]
    if key.hasPrefix("--"), i + 1 < argv.count {
        args[String(key.dropFirst(2))] = argv[i + 1]
        i += 2
    } else {
        i += 1
    }
}

let today: String = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: Date())
}()

guard let keyPath = args["key"] else { die("缺少 --key <私钥文件>") }
guard let id = args["id"], !id.isEmpty else { die("缺少 --id <授权编号>") }
guard let email = args["email"], email.contains("@") else { die("缺少或无效 --email") }
let plan = args["plan"] ?? "pro"
guard ["pro", "team"].contains(plan) else { die("--plan 仅支持 pro / team") }

let privateKey: Curve25519.Signing.PrivateKey
do {
    let raw = try String(contentsOfFile: (keyPath as NSString).expandingTildeInPath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard let data = Data(base64Encoded: raw) else { die("私钥不是合法的 base64") }
    privateKey = try Curve25519.Signing.PrivateKey(rawRepresentation: data)
} catch {
    die("读取私钥失败：\(error.localizedDescription)")
}

let license = License(v: 1, id: id, email: email, plan: plan,
                      issuedAt: args["issued"] ?? today,
                      expiresAt: args["expires"])
let payload = try JSONEncoder().encode(license)
let signature = try privateKey.signature(for: payload)
let token = "fv1." + b64url(payload) + "." + b64url(signature)

if let out = args["out"] {
    try token.write(toFile: (out as NSString).expandingTildeInPath, atomically: true, encoding: .utf8)
    print("已写入 " + out)
} else {
    print(token)
}
print("授权: id=\(license.id) plan=\(license.plan) issued=\(license.issuedAt) expires=\(license.expiresAt ?? "永久")")
