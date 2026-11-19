### 结论：品牌更名为 Pastward，机器标识刻意保留旧拼写（v4.2.31）

- 原因：「FileVault」与 macOS 磁盘加密撞名（搜索混淆 + 审核风险）；「Pastward」经全网检索无软件占用、语义与「文件时光机」同构。原四候选全部撞名证伪（docs/06 §5）。
- 取舍：bundle id com.filevault.FileVault、配置目录 ~/Library/Application Support/FileVault、refs/filevault/backup、模块名**不改**——UpdateGuard 钉 bundle id 保更新链、配置在老路径保迁移；代价是 Finder 里自动升级用户的 .app 文件夹仍叫旧名（重装一次即换）。
- 证据：Sources/FileVaultCore/AppBrand.swift（productName + 注释）、Tests/FileVaultTests/BrandTests.swift（5 项钉住契约）、scripts/make_app.sh:17；2026-11-19 web 冲突检索。
- 影响：未来任何"顺手统一名字"的改动都会破坏老用户升级/迁移，BrandTests 与 AppBrand 注释已立此存照；新用户可见面一律用 Pastward。
