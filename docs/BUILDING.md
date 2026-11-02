# 本地构建

## macOS

需要 macOS、Xcode Command Line Tools。运行：

```sh
bash scripts/build-macos.sh universal
bash scripts/package-macos-variants.sh
```

也可双击 `macos/build.command`。默认生成 Intel 与 Apple 芯片通用包，再拆分单芯片包，输出到 `dist`。最低部署目标 macOS 12。默认临时签名；可用 `MACOS_SIGN_IDENTITY` 指定本机签名身份，公证需另行配置。

脚本回归：`node macos/Tests/reader.test.cjs`。在具备图形会话的 Mac 上运行原生夹具：`bash scripts/test-macos.sh`。

## Windows

需要 Windows 10 22H2／11 x64、.NET SDK 10.0.402（由 global.json 固定），首次构建需要联网下载依赖。

```powershell
dotnet run --project windows/Tests/FloatingReader.Tests.csproj -c Release
./scripts/build-windows.ps1
```

输出带 windows/VERSION 版本号的 `dist/FloatingReader-Windows-x64-<版本>-preview.zip`，包含运行时，但 WebView2 与系统 OCR 依赖仍需系统提供。Windows UI 使用 WPF、WebView2 Composition Control 与 Windows OCR，不是把 macOS 可执行文件重命名。两个版本共享网页读取脚本，但分别使用本机窗口、字体及按键。

GitHub Actions 自动执行构建和可移植逻辑检查。发布流程见 [上传指南](UPLOAD_TO_GITHUB.md)。

## 重新生成 macOS 图标

原图保留在 assets/logo.png。安装 Node.js 与 sharp 后，运行 `node scripts/build-macos-icon.cjs`，生成带圆角及外侧留白的 assets/macos-icon.png 和完整 ICNS。仅改变 macOS 外框形状，不修改原图内容。
