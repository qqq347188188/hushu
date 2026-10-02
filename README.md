# DebFixer (iOS / TrollStore)

手机端修复 `.deb` 里 `DEBIAN/control` 权限异常的工具，解决 hoshu 转换时
`The file "control" couldn't be opened because you don't have permission to view it`
导致 "No converted file was produced" 的问题。

功能等价于 Windows 上的 Python 修复脚本：重新打包 ar 归档，把
`control.tar.gz` 内所有成员权限放宽到可读、属主重置为 root，并修正 ar 成员名格式，
让 `dpkg-deb` 能正常读取。

## 用 GitHub Actions 构建（Windows 用户适用）

1. 在 GitHub 新建一个**空仓库**（如 `DebFixer-iOS`）。
2. 把本目录所有文件（`project.yml`、`Sources/`、`README.md`、`.github/`）上传到仓库。
3. 进入仓库 **Actions** 标签，若提示则启用 Workflow。
4. 在左侧 **Build IPA**  workflow 上点 **Run workflow**。
5. 等待几分钟，构建完成后在 **Artifacts** 里下载 `DebFixer.ipa`。
6. 把 `DebFixer.ipa` 用 **TrollStore** 安装到手机。

## 使用

**方式 A：从「文件」App 直接分享传入（推荐）**

1. 在「文件」App 里选中某个有问题的 `.deb`。
2. 点「共享」→ 在「打开方式」里选 **DebFixer**，deb 会直接传入并自动修复。
3. 修复完成后点「保存修复后的 .deb」导出到「文件」App。

**方式 B：在 App 内选择**

1. 打开 DebFixer → 点「选择 .deb」选中有问题的 deb。
2. 处理完成后点「保存修复后的 .deb」，把它存到「文件」App。
3. 在 hoshu 里选这个 `-fixed.deb` 做有根→无根转换。

> 说明：本工具只改 `control.tar.gz` 的权限/属主，不动 `data.tar.*` 与应用内容。
> 若你的 deb 是 `control.tar.xz`/`.zst` 等非 gzip 格式，暂不会处理，请告诉我补充。
