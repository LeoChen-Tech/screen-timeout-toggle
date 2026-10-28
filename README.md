# 关屏切换

一个轻量的 Windows 工具：按 **F12**，切换关屏时间并同步管理静音状态。

| 模式 | 接通电源后的自动关屏时间 | 声音 |
| --- | --- | --- |
| 短时关屏 | 无操作 10 秒后 | 自动静音 |
| 保持亮屏 | 从不 | 恢复切换前的静音状态 |

只修改接通电源时的屏幕超时，不修改电池模式、系统睡眠时间或音量大小。

## 效果

![通知效果](docs/notification.png)

白底蓝字通知，约 3 秒后自动消失，不抢焦点，不播放提示音。

## 下载与安装

适用于 **Windows 11 x64**。发布包已包含 .NET 和 Windows App SDK 运行库。

1. 从 [Releases](https://github.com/LeoChen-Tech/screen-timeout-toggle/releases/latest) 下载 `ScreenTimeoutToggle-v1.0.0-win-x64.zip`。
2. 解压整个文件夹，双击 `Install.vbs` 并确认安装。
3. 使用 **F12** 或桌面的 **关屏切换** 快捷方式。

安装到 `%LOCALAPPDATA%\Programs\ScreenTimeoutToggle`，仅对当前用户生效，自动添加登录启动项，无需管理员权限。安装完成后可以删除下载的压缩包和解压目录。

## 使用说明

- 单按 F12 切换，长按不重复触发；Ctrl / Alt / Shift / Win + F12 保留原用途。
- 笔记本处于多媒体键优先模式时，可能需要按 **Fn + F12**。
- F12 原有的浏览器开发者工具等功能会被占用。
- 操作期间显示“正在切换”，完成后显示实际结果。
- 恢复的是之前的静音状态；若之前本来静音，切回“从不”后仍然静音。
- 全屏应用、管理员窗口、键盘固件及其他热键软件可能影响快捷键。

## 卸载

先切回“从不”，再运行安装目录中的 `Uninstall.vbs`。卸载会移除程序、桌面快捷方式和登录启动项，不会修改当前电源或声音设置。

## 注意

程序暂未进行代码签名，Windows 可能提示未知发布者。请核对下载来源和 Release 中的 SHA-256，不要关闭系统安全保护。若单位策略禁用 VBScript 或脚本执行，请遵循设备管理规定。

目前已在开发电脑完成自包含运行、安装文件校验和纯预览验证；尚未在独立的全新 Windows 系统上验证。

## 开发

源码位于 `src/ToastHost`，电源和声音脚本位于 `outputs`。构建需要 Windows 和 .NET 8 SDK：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File build\Publish.ps1
```

发布包输出到 `dist`。通知测试使用 `-PreviewToast`，不执行实际关屏和静音切换。
