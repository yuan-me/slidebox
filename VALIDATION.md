# 验证 / Validation

早期测量环境：macOS 26.6.2 · Apple Silicon · Swift 6.3.3。macOS 15 和 Intel 的实际运行尚未验证；通用二进制包含 arm64/x86_64，最低系统版本为 15.0。

## 回到设定页面（v0.1.2，2026-09-21）

- 网站图标右键菜单新增始终可用的“回到设定页面”；切换到目标网站并重新打开收藏网址。用户已确认安装版功能正常。
- 本地网页回归覆盖普通搜索、SPA、休眠释放后及已在首页时返回，验证目标网站激活、收藏不变、登录存储保留，以及再次休眠后不恢复旧搜索页。
- 图标缓存直接复用已生成的缩略图，删除写入 PNG 后再次解码的步骤；图标下载、缓存清理及布局自检通过。未重新测量整体 CPU 或内存，不声称量化性能提升。
- arm64/x86_64 release 构建、ad-hoc 签名校验、纯逻辑和三种尺寸布局自检通过；两个架构的 Mach-O 最低系统版本均为 15.0。Intel 和 macOS 15 未做实际运行验证。

## 收藏与缓存修复（2026-09-16）

本次环境：macOS 27.0 · Apple Silicon · Swift 6.4。arm64/x86_64 release 构建与 ad-hoc 签名校验通过，两个架构的 Mach-O 最低系统版本均为 15.0。构建脚本改用 SwiftPM 返回的产物路径，以兼容 Swift 6.4 默认构建引擎。

- 本地 HTTP 回归检查通过：SPA 跳转不改写收藏，快速返回复用网页，休眠释放后恢复当前地址，新会话从收藏地址进入，手动编辑仍可保存。
- 在独立持久化 WebKit 测试存储中，连续请求先命中资源缓存；清理后重新请求服务器。Cookie、Local Storage 和 IndexedDB 在重建网页后均保留。
- 独立图标缓存的内存和磁盘清理、重复清理，以及阻止清理前的下载回写均通过检查。
- 纯逻辑、三种尺寸下的原生布局、29 秒内复用、超时释放、关闭/调整休眠及 20 次创建/释放循环检查通过。

复现：构建后运行 `/opt/homebrew/Caskroom/miniconda/base/envs/py312/bin/python3 scripts/check-data.py`。测试仅访问本机网页；未验证真实网站登录流程或重新测量内存。密码钥匙串不在清理代码的访问范围内；网站自身登录过期不受此功能控制。

### 界面与资源精简（同日后续）

- 删除缓存区说明文字，直接更新按钮的清理中、完成、失败状态及辅助功能标签；无需重建设置页。
- 预览错位已用填入 GMail 的表单复现：外框仅 13pt 高，文字区域 35pt 高。补齐 NSBox 高度约束后，外框为 57pt，图标与文字居中，三种宽度下均有足够内边距。
- 移除每个网页的 URL KVO 观察者和每次导航生成的 Task，在网页释放前读取当前 URL。后台 SPA 导航、快速返回、休眠恢复及收藏保持不变通过回归检查。
- 图标下载会话按需创建，禁用与缩略图缓存重复的 URLCache；请求尝试记录改用 countLimit 为 100 的 NSCache，可在内存压力下回收。
- 29 秒内复用、休眠释放、关闭/调整休眠和 20 次释放循环再次通过。优化前对实际应用的三秒采样显示各线程均等待事件，没有发现持续轮询；本次不声称整体内存或 CPU 降低了某个百分比。

布局自检现包含真实预览内容、居中/边界检查和按钮反馈检查。设置 `SLIDEBOX_LAYOUT_OUTPUT` 为应用自身沙箱内的临时目录，可导出表单渲染图；不访问实际网站账号。

## 内存 / Memory

默认开启 30 秒休眠，逐个访问网站公开入口，未登录或发送消息。以下是测试应用和测试期间新增 WebKit 进程的 RSS 合计：

| 网站 / Website | 加载后 / Loaded | 隐藏约 35 秒 / Hidden ~35s | 隐藏约 90 秒 / Hidden ~90s |
| --- | ---: | ---: | ---: |
| DeepSeek | 295.58 MiB | 135.19 MiB | 100.81 MiB |
| ChatGPT | 619.05 MiB | 182.50 MiB | 98.06 MiB |

两个页面的 WKWebView 弱引用都在超时后变为 nil，网页内容进程退出；90 秒时仍有网络缓存进程。未创建网页时，20 秒内 RSS 约 54 MiB，CPU 采样为 0.0%。

RSS 可能重复统计共享内存，不等于系统物理内存节省量；新增进程按启动前基线筛选，其他应用同时创建 WebKit 进程可能干扰结果。仅为一次设备上的采样，不保证所有网页有相同表现。

RSS totals can double-count shared pages and are not physical-memory savings. Results are from one device; unrelated WebKit processes may affect sampling. Login sessions, streaming responses, and long-term workloads were not tested.

## 检查 / Checks

- 配置编码、网址校验、拖动排序逻辑、自定义休眠时间和关闭休眠通过自检。
- 添加/设置页在三种窗口尺寸下通过原生布局检查。
- 29 秒内复用，超时释放；20 次创建/释放循环无残留 WKWebView 弱引用。测试运行器防止 App Nap 干扰断言；正常产品不阻止 App Nap。
- 实际鼠标拖放、多显示器、登录启动、Spaces、登录态流式聊天尚未完整验证。

复现网页内存采样：构建应用后，使用 Python 3 运行 `scripts/check-memory.py`（约 5 分钟，将访问上述两个公开网址）。

## 浏览器标识与网站图标（2026-09-08）

网页标识补充本机 Safari 版本。Gmail、DeepSeek、ChatGPT 入口加载完成后，均未检测到 “This browser version is no longer supported” 提示；未验证登录后的邮箱操作或聊天。

本地 HTTP 页面中声明的自定义图标已自动下载、缩略并缓存；来源键隔离及 Safari 标识检查通过。图标请求不使用额外网页实例，单图限制 512 KiB，缩略至 64px，缓存 7 天。

复现：构建后运行 `python3 scripts/check-browser.py`。此检查会访问上述三个网站。
