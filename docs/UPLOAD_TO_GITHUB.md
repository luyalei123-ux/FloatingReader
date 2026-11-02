# 上传 GitHub 并提供下载

本次发布准备：macOS 0.26.18、Windows 0.29.2 preview。源码和下载包已分开整理，尚未上传或发布。

## 1. 上传干净源码

使用 `FloatingReader-Source-v0.26.18.zip`，解压得到 `FloatingReader-GitHub`。保留隐藏的 `.github`、`.gitignore` 文件。不要上传外层历史项目目录，也不要把 `dist`、`bin`、`obj` 或账号目录加入源码。

建议使用 GitHub Desktop：

1. 选择 File → Add local repository，定位解压后的源码文件夹；如果提示不是仓库，选择创建本地仓库。
2. 使用 main 分支，提交源码，再 Publish repository，自行选择仓库名称和公开范围。
3. 打开仓库 Actions，检查 `Build and package`。源码包内的配置会构建 macOS 与 Windows，执行脚本及可移植逻辑检查。

也可使用 Git：

```sh
git init -b main
git add .
git commit -m "Prepare FloatingReader v0.26.18 preview"
git remote add origin https://github.com/YOUR-NAME/FloatingReader.git
git push -u origin main
```

把示例地址替换为自己的空仓库地址。不要将个人访问令牌写入源码或命令示例文件。

## 2. 创建测试版下载

可以先手动创建 Release 草稿：

1. 打开 Releases → Draft a new release，标签使用 `v0.26.18`，目标为本次源码提交。
2. 标题填写「浮读 v0.26.18 测试版」，说明复制 `docs/RELEASE_NOTES.md`。
3. 勾选预发布（pre-release），把发布目录内的三个平台 ZIP、干净源码 ZIP 和 SHA256SUMS.txt 拖入附件区域。
4. 检查版本及验证状态，保存草稿。准备公开后再发布。

ZIP 是附件，不要把整个 release 文件夹提交到仓库源码中。

## 3. 使用自动发布草稿

也可以等 Actions 构建成功后推送标签：

```sh
git tag v0.26.18
git push origin v0.26.18
```

自动流程会重新构建 macOS Intel、Apple 芯片、universal 以及 Windows x64，生成校验值，再创建标记为预发布的 Release 草稿。自动构建附件的版本号来自 VERSION 和 windows/VERSION。

首次工作流尚未在目标仓库执行，不能把本地交叉编译结果当作 GitHub Actions 已通过。若组织限制了 Actions 写入权限，需允许发布任务写入仓库内容，再重跑。

## 4. 发布前最后核对

- 首页和 Release 都标明测试版、平台版本和已知限制。
- Windows、Apple 芯片实机验证尚未完成时保留提示。
- 不提交 Cookies、WebView2 用户数据、阅读记录、个人路径、令牌或签名证书。
- 保留 MIT、图标及运行时等第三方许可证。
- macOS 签名公证和 Windows 发布者签名尚未配置；后续另行使用自己的证书，不提交密码或私钥。

## 后续版本

先更新应用版本、发布说明并完成验证，再创建新的版本标签；不要用新文件覆盖同一标签的旧公开版本。需要重新整理干净源码与本地附件时，可先生成各平台版本包，再运行 `python3 scripts/prepare-release.py`。
