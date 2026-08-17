# Thermometer for macOS

Thermometer 是原生 macOS 菜单栏硬件温度监视器，可显示 CPU、GPU、内置硬盘、电池温度和风扇转速，并按需控制风扇。

## 功能

- 菜单栏动态显示任意硬件指标
- 点击图标打开玻璃质感仪表盘
- 菜单栏图标支持自动黑白、固定黑色、固定白色和自定义图片
- 屏幕悬浮 HUD 支持紧凑横条、卡片面板、竖向列表
- HUD 可调项目、内容形式、缩放、位置、透明度、模糊、置顶和点击穿透
- 关闭点击穿透后可直接拖动 HUD，自定义位置会按屏幕保存
- HUD 使用原生 `NSVisualEffectView` 实时透明毛玻璃效果
- 风扇控制支持三种模式：系统自动、按温度曲线、自定义转速
- 按温度模式在芯片够热后提高转速，自定义模式锁定指定转速
- 退出、睡眠或切回系统自动时，把风扇控制权交还给 macOS
- Apple Silicon M1–M5 与 Intel 运行时动态探测
- Universal 2（arm64 + x86_64），最低 macOS 13
- 零网络请求、零第三方运行时依赖、无需 root

## 构建

```bash
./scripts/build.sh
```

产物位于 `dist/Thermometer.app`。脚本只使用系统已有的 Swift、AppKit、SwiftUI 和 IOKit。每次打包会替换为当前版本，并清理中间编译缓存。

## 传感器说明

Apple 没有为 CPU/GPU 温度提供稳定的公开 API。本项目以只读方式使用 AppleSMC 和 Apple Silicon HID 温度通道，并在接口不可用时显示“—”，不会伪造数据。不同机型可用传感器不同；外接硬盘通常不提供无需驱动即可读取的温度。

风扇转速通过 SMC 读写。默认不改转速；只有选择“按温度”或“自定义”后才会写入目标转速，并限制在硬件报告的最低/最高范围内。部分无风扇或只读机型会保持监视、不提供控制。

应用未启用 App Sandbox，适合本机安装和直接分发，不适合 Mac App Store。未配置 Developer ID 时会采用 ad-hoc 签名；其他 Mac 首次启动可能需要在 Finder 中右键选择“打开”。

## 清理

```bash
./scripts/clean-build-cache.sh
```

项目不安装 Homebrew 包、Python 包、npm 包或其他工具。清理脚本只删除本项目的 `.build`，不会触碰用户已有的 Homebrew、Swift 或系统缓存。
