# 验证 / Validation

macOS 26.6.2 · Apple Silicon · Swift 6.3.3。macOS 15 和 Intel 的实际运行尚未验证；通用二进制包含 arm64/x86_64，最低系统版本为 15.0。

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
