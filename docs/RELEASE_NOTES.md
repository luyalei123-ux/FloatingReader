# 浮读 v0.26.18 测试发布

这是公开发布准备版。macOS 应用版本 0.26.18；Windows 应用版本 0.29.2 preview，两端版本独立。

## 下载文件

- Intel Mac：FloatingReader-macOS-Intel-0.26.18.zip
- Apple 芯片 Mac：FloatingReader-macOS-AppleSilicon-0.26.18.zip
- Windows x64：FloatingReader-Windows-x64-0.29.2-preview.zip
- 干净源码包：FloatingReader-Source-v0.26.18.zip
- SHA256SUMS.txt：下载文件校验值

GitHub Actions 还可生成 macOS universal 通用包；本次本地发布目录提供上列两个单芯片包。

## 主要功能

置顶与取消置顶、自动纯文字、后台循环预读、滚到底接续、章节目录、本机字体、字号滑块、行距、独立文字与背景配色、统一隐藏／显示、阅读区域拖动、可修改快捷键与本地书签。

模式按钮表示切换目标：内容是纯文字时显示「原网页」，内容是网页时显示「纯文字」。显式点击先恢复应用焦点，再处理拖动。读取推进结合已识别边界，空识别同位置重试，失败保留读取位置。

## 验证范围与已知问题

Intel 环境完成相应原生回归；Apple 芯片与 Windows 包为交叉编译，尚待对应实机验证。CI 配置已准备，尚未在目标 GitHub 仓库运行。

OCR 可能错字、漏字或重复；网页变化可能影响读取和切章，真实书籍、长时闲置与跨设备进度同步仍需验证。预读受网络、系统 OCR 和访问权限影响，不保证零等待。遇到遗漏请切回原网页核对。

macOS 包为临时签名、未公证；Windows 包未做发布者签名。首次打开请按操作系统的安全提示处理，不建议关闭系统保护。

先退出旧版，再完整解压替换。Windows 不要只复制 exe。升级后需要重新读取先前已漏字的缓存章节。
