# Slidebox

<img src="Assets/Slidebox-icon.png" width="128" alt="Slidebox icon">

**完全开源免费，为低系统开销而设计的 macOS 侧栏浏览器。**

使用 Swift、AppKit 和系统 WebKit 原生构建，无第三方代码依赖。将常用网页收进屏幕侧边，需要时随手划出。

- **轻量运行**：不轮询鼠标、不预加载网页。
- **自动休眠**：网页隐藏后默认 30 秒释放，重新打开时加载；可关闭休眠或自定义时间。
- **简单好用**：边缘悬停展开、拖动图标排序、自由调整窗口大小、固定侧栏。

支持 **macOS 15+ · Apple Silicon / Intel**。

休眠保留网站登录数据，但未发送的输入和正在生成的回答可能无法恢复。实测与限制见 [验证记录](VALIDATION.md)。

---

**A fully free and open-source macOS sidebar browser, designed for low system overhead.**

Built natively with Swift, AppKit, and system WebKit, with no third-party code dependencies. Keep your favorite websites at the edge of your screen, ready to slide into view.

- **Lightweight**: no mouse polling or webpage preloading.
- **Automatic sleep**: hidden pages are released after 30 seconds by default and reloaded when needed. Disable sleep or choose your own delay.
- **Simple controls**: edge-hover access, drag-to-reorder icons, resizable windows, and pinning.

Requires **macOS 15+ · Apple Silicon / Intel**.

Sleep preserves website login data, but unsent input and ongoing responses may not recover. See [validation results and limitations](VALIDATION.md).

## 构建 / Build

Install Apple Command Line Tools with Swift 6+, then run:

```sh
bash scripts/build.sh
```

输出 / Output: `dist/Slidebox.app`

[图标来源 / Asset credits](Assets/CREDITS.md)

[下载 / Download](https://github.com/yuan-me/slidebox/releases/latest) · [使用说明 / Usage](docs/USAGE.zh-CN.md) · [MIT License](LICENSE)
