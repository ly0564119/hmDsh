# 爱普生 L805 打印（HarmonyOS NEXT）

一个 **HarmonyOS NEXT（ArkTS）** 原生应用，通过 Wi-Fi 局域网用爱普生 **ESC/P-R** 栅格协议
直接驱动 **爱普生 L805**（6 色喷墨照片打印机）。不依赖官方 Epson iPrint，也不需要打印机联网。

**支持打印**：纯文本（.txt）、照片、Word（.docx）、Excel（.xlsx），并支持**局域网自动发现打印机**。

> PDF 暂不支持：当前 SDK 没有公开的 PDF 页面渲染 API，见文末「PDF 说明」。

## ⚠️ 先说清楚：L805 没有扫描功能

L805 是一台**单功能照片打印机**，硬件上没有扫描仪，任何 App 都无法让它“扫描”。
本应用只做**打印**。需要扫描请换带扫描的 L 系列一体机（L3150 / L3250 / L6290 等）。

## 工作原理

1. 选文件（txt / docx / xlsx）或相册选图。
2. 排版成「页面内容」（文本行 / 表格网格线 / 图片摆放），只算坐标不碰像素：
   - 文本：逐字测量折行，中文逐字断、英文优先在空格断；
   - Word：内存解 ZIP → `word/document.xml` → 提取文字，按文本排版；
   - Excel：内存解 ZIP → `sharedStrings.xml` + `sheet1.xml` → 渲染成带网格线的表格；
   - 照片：解码后等比缩放居中，横图打纵向纸时自动旋转 90°。
3. 用 `@kit.ArkGraphics2D` 的 `drawing` 把页面**按渲染带**画到 RGBA 位图上（坐标与字号都是物理像素）。
4. 每渲染完一带就编码成 **ESC/P-R** 命令并发往打印机 **IP:9100**，全程流式，不在内存里保留整页栅格。

关键实现点：

- ESC/P-R 命令格式是 `ESC + 分类(1B) + 参数长度(4B 小端) + 命令名(4B ASCII) + 参数`，
  **注意长度字段是小端，而参数里的坐标/尺寸是大端**。
- 作业流程：退出 IEEE-1284.4 包模式 → `ESC @` → `REMOTE1`（TI/JS/JH/PP）→ 进入 `ESC/P-R`
  → `setq`（介质/质量/色彩）→ `setj`（纸张/边距/可打印区/分辨率）→ 逐页 `sttp`/`setn`
  → 逐行 `dsnd` → `endp` → `endj` → `JE` 收尾。
- 栅格是 **RGB888 逐行**发送，可选官方 RLE 压缩（全白行能从 8.7KB 压到不足 100 字节），
  L805 固件内部完成 RGB→青/品/黄/黑/浅青/浅墨 的分色与抖动，主机不需要分色。
- 命令字节取自 Epson 官方开源驱动 `epson-inkjet-printer-escpr` 的 `lib/epson-escpr-api.c`
  （另与 `ezrec/python-epson` 的实现交叉验证）。
- 局域网发现用 mDNS（`@ohos.net.mdns`），探测 `_pdl-datastream._tcp` 等打印服务。

### 两个曾经的坑（已修复）

- **照片打印出来是满页乱码**：早期实现发的是 `GS(0x1D)` 前缀的 `ESC/PAGE-COLOR` 命令，
  那是**激光打印机**的语言。L805 不认识，就把整个作业当 ESC/P2 文本打了出来。
  现在改为真正的 ESC/P-R。
- **Word 打印失败**：早期实现一是用 `zlib.decompressFile` 落盘解压（picker 返回的 URI
  不能直接当沙箱路径用），二是用 `OffscreenCanvas` 渲染文本——它的宽高按 **vp** 计量、
  会被屏幕密度缩放，`getPixelMap` 出来的位图尺寸和代码假设的 `width*height*4` 缓冲对不上，
  读像素直接抛异常。现在 ZIP/DEFLATE 全在内存里解，渲染改用 `drawing` 按物理像素进行。

## 目录结构

```
├── AppScope/                     应用级配置与图标
├── entry/src/main/
│   ├── module.json5              模块配置（INTERNET / GET_NETWORK_INFO）
│   ├── ets/
│   │   ├── entryability/EntryAbility.ets
│   │   ├── pages/Index.ets       主界面
│   │   ├── common/
│   │   │   ├── Constants.ets     纸张规格/边距/端口等常量
│   │   │   ├── ByteWriter.ets    字节流拼装（大小端）
│   │   │   ├── Inflate.ets       DEFLATE 解压（RFC 1951）
│   │   │   ├── Utf8.ets          UTF-8 解码（含 BOM）
│   │   │   └── ZipReader.ets     内存 ZIP 读取（docx/xlsx）
│   │   └── model/
│   │       ├── RasterImage.ets   RGB 位图容器
│   │       ├── PrinterConnection.ets  TCP 连接（分块发送）
│   │       ├── PrinterDiscovery.ets   mDNS 发现
│   │       ├── PageContent.ets   页面内容模型（文本/网格/图片）
│   │       ├── TextFont.ets      字型与字宽测量
│   │       ├── PageRenderer.ets  分带栅格化（drawing → PixelMap）
│   │       ├── DocumentRasterizer.ets 排版（折行/分页/表格/照片）
│   │       ├── OfficeParser.ets  docx/xlsx XML 解析
│   │       ├── EscPrEncoder.ets  ESC/P-R 编码器（核心）
│   │       └── PrintService.ets  打印流程编排
│   └── resources/
├── tools/verify/verify.mjs       纯逻辑自测脚本（Node 运行，见下）
├── build-profile.json5           compatibleSdkVersion = 6.1.1(24)
└── oh-package.json5
```

## 构建与运行

1. 安装 **DevEco Studio**（本项目按 **HarmonyOS 6.1.1 / API 24** SDK 配置）。
2. `File → Open` 打开本工程根目录。
3. 配置**自动签名**（`File → Project Structure → Signing Configs`）。
4. 连接 HarmonyOS 6.1.1（API 24）真机，点击 **Run**。

> 如果你用更低的 SDK/设备：把 `build-profile.json5` 里的
> `compatibleSdkVersion`（以及 `targetSdkVersion`）改成你 SDK 对应的版本即可，
> 格式为 `平台版本(API 版本)`，例如 `5.0.0(12)`。改完在 DevEco 里 Sync 一下。
> 渲染用到的 `drawing`（`drawSingleCharacter` / `SamplingOptions`）与
> `image.createPixelMapSync` 需要 **API 12 及以上**。

## 纯逻辑自测

协议编码、DEFLATE、ZIP、docx/xlsx 解析这几块「错一个字节就整页乱码」的逻辑不依赖任何
HarmonyOS API，可以直接用 Node（>= 20）跑真数据验证：

```bash
node --experimental-strip-types tools/verify/verify.mjs
```

脚本会：用 Node zlib 生成的真实压缩流对拍 DEFLATE 解压；现场构造真实的 .docx / .xlsx
ZIP 包跑完整解析链；把生成的 ESC/P-R 字节流重新解析回位图，与源位图逐像素比对。

## 使用步骤

1. 手机和 L805 连**同一路由器**。
2. 点「发现」自动扫描，或在输入框手动填 IP。
3. 选纸张、质量（标准 360dpi / 高质量 720dpi）、纸张类型与色彩。
4. 点对应按钮选择文件打印。

## 各格式保真度说明（重要）

- **.txt**：单字体、单字号、左对齐的简单排版（UTF-8 编码，自动跳过 BOM）。
- **.docx**：**提取文字内容**打印，会丢失字体、字号、颜色、图片、复杂版式——相当于“纯文字版”；
  表格按「单元格用制表符分隔、整行一行」输出。
- **.xlsx**：渲染成**带网格线的表格**，单元格文字自动换行；不保留合并单元格、公式、图表、列宽样式；
  日期等按单元格里的原始值输出（不做数字格式化）。
- **照片**：等比缩放居中，横图打纵向纸时自动旋转 90°；不做 EXIF 方向校正。
- **页边距**：按爱普生喷墨机通用值取的保守值——三边 3mm，普通纸底边 14mm；
  照片纸尺寸四边 3mm。想贴边打印可以改 `common/Constants.ets` 里的 `PaperSpec`。
- 暂不支持无边距（borderless）打印与双面打印。

这些都是“内容优先”的轻量实现，达不到 WPS / 官方驱动的排版还原度。

## PDF 说明

当前 HarmonyOS 6.1.1（API 24）的公开 SDK 里**没有** PDF 页面渲染 API（`@kit.PDFKit` /
`pdfService` / `PdfReader` 均未在 SDK 中暴露），所以本项目暂未内置 PDF 打印。

如需 PDF 打印，可行方向（需另行接入）：
- 引入第三方 ohpm PDF 渲染库（如 OpenHarmony-TPC 的 pdfViewer 系列，多为 native 库，需 NDK 编译）；
- 使用商业 SDK（如 Foxit PDFSDK-Harmony），按它的授权方式集成；
- 或用 PDF 阅读器/系统能力先把 PDF 导出为图片再打印。

## 常见问题

- **打印失败**：界面会显示具体原因（连接失败 / 发送失败 / 文档解析失败）。
  先确认 IP 正确、同一网段、防火墙未拦 9100；可先 ping 打印机 IP。
- **发现不到打印机**：部分路由器会隔离 mDNS 组播，改用**手动输入 IP**（最稳）。
- **打印出满页乱码字符**：说明发过去的不是 ESC/P-R。本版已修；若你改过 `EscPrEncoder`，
  先跑一遍上面的自测脚本。
- **Word/Excel 打不开**：确认是标准 .docx/.xlsx（不是旧 .doc/.xls，也不能是加密文档）。
- **打印很慢**：720dpi 的 A4 一页原始数据超过 100MB，靠 RLE 压缩后仍然不小，
  Wi-Fi 传输需要时间；文字文档用 360dpi 就够了。
