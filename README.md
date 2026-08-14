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
2. 光栅化成 RGB 位图：
   - 文本：`OffscreenCanvas` 排版；
   - 照片：`ImageSource` 解码缩放；
   - Word：解 ZIP → `word/document.xml` → 提取文字，按文本打印；
   - Excel：解 ZIP → `sharedStrings.xml` + `sheet1.xml` → 渲染成带网格线的表格。
3. 拼装 **ESC/P-R** 打印任务（EJL 握手 + 栅格命令 + RGB888 数据）。
4. 通过 `@ohos.net.socket` 发送到打印机 **IP:9100**。

关键实现点：

- ESC/P-R 命令前缀是 **GS（0x1D）**，不是 ESC（0x1B，那是老的 ESC/P2）。
- 颜色以 **RGB888 直传**，L805 固件内部完成 RGB→青/品/黄/黑/浅青/浅墨 分色与抖动。
- 命令字节取自 Epson 官方开源驱动 `epson-inkjet-printer-escpr` 的
  `lib/epson-escpage.c` / `lib/epson-escpage-color.c`。
- 局域网发现用 mDNS（`@ohos.net.mdns`），探测 `_pdl-datastream._tcp` 等打印服务。

## 目录结构

```
├── AppScope/                     应用级配置与图标
├── entry/src/main/
│   ├── module.json5              模块配置（INTERNET / GET_NETWORK_INFO）
│   ├── ets/
│   │   ├── entryability/EntryAbility.ets
│   │   ├── pages/Index.ets       主界面
│   │   ├── common/
│   │   │   ├── Constants.ets     端口/分辨率/纸张常量
│   │   │   ├── ByteWriter.ets    字节流拼装
│   │   │   └── ZipReader.ets     极简 ZIP 读取（docx/xlsx 解包）
│   │   └── model/
│   │       ├── RasterImage.ets   RGB 位图容器
│   │       ├── PrinterConnection.ets  TCP 连接
│   │       ├── PrinterDiscovery.ets   mDNS 发现
│   │       ├── DocumentRasterizer.ets 文本/图片/表格 → 位图
│   │       ├── OfficeParser.ets  docx/xlsx XML 解析
│   │       ├── EscPrEncoder.ets  ESC/P-R 编码器（核心）
│   │       └── PrintService.ets  打印流程编排
│   └── resources/
├── build-profile.json5           compatibleSdkVersion = 6.1.1(24)
└── oh-package.json5
```

## 构建与运行

1. 安装 **DevEco Studio**（本项目按 **HarmonyOS 6.1.1 / API 24** SDK 配置）。
2. `File → Open` 打开本工程根目录（`D:\119\workspace\ai\hm`）。
3. 配置**自动签名**（`File → Project Structure → Signing Configs`）。
4. 连接 HarmonyOS 6.1.1（API 24）真机，点击 **Run**。

> 如果你用更低的 SDK/设备：把 `build-profile.json5` 里的
> `compatibleSdkVersion`（以及 `targetSdkVersion`）改成你 SDK 对应的版本即可，
> 格式为 `平台版本(API 版本)`，例如 `5.0.0(12)`。改完在 DevEco 里 Sync 一下。

> 本工程由 AI 生成，未在 DevEco Studio 实际编译；如个别 API 类型名/方法名与你的 SDK
> 有差异，按 IDE 自动补全微调即可。

## 使用步骤

1. 手机和 L805 连**同一路由器**。
2. 点「发现」自动扫描，或在输入框手动填 IP；选纸张（A4 / Letter / 4x6 明信片）与质量（300/600 dpi）。
3. 点对应按钮选择文件打印。

## 各格式保真度说明（重要）

- **.txt**：单字体、单字号、左对齐的简单排版（UTF-8 编码）。
- **.docx**：**提取文字内容**打印，会丢失字体、字号、颜色、图片、表格等复杂排版——相当于“纯文字版”。
- **.xlsx**：渲染成**带网格线的表格**，单元格文字自动换行；不保留合并单元格、公式、图表、列宽样式。
- **照片**：等比缩放居中，纸张边距按官方 300dpi 表换算。
- **4x6 照片**暂映射到“明信片”规格（100×148mm），与 4x6（102×152mm）略有差异。

这些都是“内容优先”的轻量实现，达不到 WPS / 官方驱动的排版还原度。

## PDF 说明

当前 HarmonyOS 6.1.1（API 24）的公开 SDK 里**没有** PDF 页面渲染 API（`@kit.PDFKit` /
`pdfService` / `PdfReader` 均未在 SDK 中暴露），所以本项目暂未内置 PDF 打印。

如需 PDF 打印，可行方向（需另行接入）：
- 引入第三方 ohpm PDF 渲染库（如 OpenHarmony-TPC 的 pdfViewer 系列，多为 native 库，需 NDK 编译）；
- 使用商业 SDK（如 Foxit PDFSDK-Harmony），按它的授权方式集成；
- 或用 PDF 阅读器/系统能力先把 PDF 导出为图片再打印。

## 常见问题

- **打印失败**：确认 IP 正确、同一网段、防火墙未拦 9100；可先 ping 打印机 IP。
- **发现不到打印机**：部分路由器会隔离 mDNS 组播，改用**手动输入 IP**（最稳）。
- **Word/Excel 乱码或空白**：确认是标准 .docx/.xlsx（不是旧 .doc/.xls）。
- **文本乱码**：把 .txt 另存为 UTF-8。
