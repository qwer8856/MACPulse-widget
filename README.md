# MacPulse Widget

原生 macOS 系统状态小组件，使用 SwiftUI 和 WidgetKit 显示 CPU、内存、磁盘占用及供电功率。支持小、中、大三种尺寸，在系统“编辑小组件”中添加，应用不会创建置顶悬浮窗。

当前版本：**2.0.3**。安装后的应用和小组件名称均为 **“系统状态”**。

## 示例图片

以下为同一份真实采样数据生成的小组件预览；数值仅作示例，会随设备和运行状态变化。

### 中号

<img src="docs/images/medium.png" width="344" alt="中号系统状态小组件，包含 CPU、内存、磁盘、功率和内存压力">

### 小号与大号

<img src="docs/images/small.png" width="164" alt="小号系统状态小组件">
<img src="docs/images/large.png" width="344" alt="大号系统状态小组件">

## 环境要求

- Apple Silicon Mac（M 系列）；当前脚本只构建 arm64，不支持 Intel。
- 运行需要 macOS 14 或更新版本。
- 构建需要较新的 Xcode Command Line Tools，或包含 macOS SDK 的完整 Xcode。已在 macOS 26.6.2、Swift 6.2.1 环境构建验证，旧工具链未验证。
- 无第三方依赖，不需要服务器、数据库或付费开发者账号即可本地构建。

## 构建与安装

1. 安装 Apple 开发工具。已经安装的设备可跳过，首次安装须等待系统安装器完成：

   ```sh
   xcode-select --install
   ```

2. 下载源码：

   ```sh
   git clone https://github.com/qwer8856/MACPulse-widget.git
   cd MACPulse-widget
   ```

3. 编译并安装至“应用程序”，当前账户须有该目录的写入权限：

   ```sh
   zsh build.sh /Applications
   pluginkit -a '/Applications/系统状态.app/Contents/PlugIns/SystemStatusWidget.appex'
   open '/Applications/系统状态.app'
   ```

   构建脚本会编译宿主与小组件扩展，完成本地临时签名并验证。成功后会输出应用路径。仅构建、不安装可执行 `zsh build.sh`，产物位于系统临时目录，具体路径以脚本输出为准。

4. 在桌面空白处右键，打开“编辑小组件”，搜索 **“系统状态”**，选择尺寸并添加。

若未找到组件，关闭并重新打开“编辑小组件”。仍未出现时可重新注册应用，再打开应用与组件列表：

```sh
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f '/Applications/系统状态.app'
pluginkit -a '/Applications/系统状态.app/Contents/PlugIns/SystemStatusWidget.appex'
open '/Applications/系统状态.app'
```

## 使用与更新

菜单栏波形图标提供刷新和组件状态查询。点击小组件或刷新图标也会请求更新。退出菜单栏程序后，桌面小组件仍由系统调度采样，无需设置后台任务或登录项。

更新时先从菜单栏退出应用，然后在源码目录执行 `git pull --ff-only`，重新执行上面的构建与安装命令。使用本仓库相同标识的版本升级通常可保留已添加的小组件。

## 数据与限制

| 指标 | 统计方式 |
| --- | --- |
| CPU | 每次系统调度时采样约 0.6 秒，显示全核心平均占用 |
| 内存 | 应用内存、系统固定内存与压缩池实际大小之和，排除文件缓存及可清除匿名页；单位 GiB |
| 内存压力 | 直接读取系统压力等级，判断内存紧张程度应结合此项 |
| 磁盘 | 内置 APFS 主容器总容量减去共享可用空间；单位 GB |
| 功率 | 读取设备供电侧遥测，单位 W；不是累计耗电量，不含外接显示器 |

- **刷新不是每秒保证执行。** 程序内置 1 秒后的刷新请求，实际执行频率由 macOS 的刷新预算和节能策略决定。
- 功率读数依赖机型及供电状态，部分设备不支持，会显示 `--`；传感器自身也可能约一分钟才更新一次。
- 功率读数超过 3 分钟会隐藏；整份采样超过 15 分钟显示“等待更新”，避免把旧数据当作当前状态。
- 程序不联网、不记录运行日志，不需要辅助功能或录屏权限。
- 构建产物使用临时签名，未经 Developer ID 签名及 Apple 公证。直接分发二进制到其他电脑可能被系统拦截；正式分发应补齐签名、公证和目标机型验证。

仓库只包含源码、构建所需资源和本文中的示例图片，不包含安装包、构建缓存或本机运行数据。
