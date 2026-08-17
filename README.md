# 爱普生 L805 打印（HarmonyOS NEXT）

一个 **HarmonyOS NEXT（ArkTS）** 原生应用，通过 Wi-Fi 局域网用爱普生 **ESC/P-R** 栅格协议
直接驱动 **爱普生 L805**（6 色喷墨照片打印机）。不依赖官方 Epson iPrint，也不需要打印机联网。

**支持打印**：纯文本（.txt）、照片、Word（.docx）、Excel（.xlsx）、**PDF**，并支持**局域网自动发现打印机**。

Word 不再抽成纯文字：先按段落/表格/图片排版成一份 PDF，再走和 PDF 相同的打印管线，
所以字号、粗斜体、颜色、对齐、表格边框和内嵌图片都会保留。

## ⚠️ 先说清楚：L805 没有扫描功能

L805 是一台**单功能照片打印机**，硬件上没有扫描仪，任何 App 都无法让它“扫描”。
本应用只做**打印**。需要扫描请换带扫描的 L 系列一体机（L3150 / L3250 / L6290 等）。

## 工作原理

1. 选文件（txt / docx / xlsx / pdf）或相册选图，**先解析，不打印**：
   - Word：内存解 ZIP → 解析样式/段落/表格/图片 → **排版成 PDF**；
   - Excel：内存解 ZIP → `sharedStrings.xml` + `sheet1.xml` → 表格数据；
   - PDF：解析交叉引用表与内容流，解释成显示列表（文字 / 矢量 / 图片）。
2. 按当前打印设置排版成「页面内容」（文本行 / 表格网格线 / 图片摆放 / PDF 绘制指令），只算坐标不碰像素：
   - 文本：逐字测量折行，中文逐字断、英文优先在空格断；
   - 表格：单元格内自动折行，按行高分页，带网格线；
   - 照片：解码后等比缩放居中，横图打纵向纸时自动旋转 90°；
   - PDF / Word：整页等比放入当前纸张的可打印区并居中。
3. **打印预览**：把排好的页面等比缩小画成一张缩略图（连纸张边距一起画），
   可逐页翻看；确认无误后点「开始打印」才会连接打印机。
4. 打印时用 `@kit.ArkGraphics2D` 的 `drawing` 把**同一份排版结果**按渲染带画到 RGBA 位图上
   （坐标与字号都是物理像素）。
5. 每渲染完一带就编码成 **ESC/P-R** 命令并发往打印机 **IP:9100**，全程流式，不在内存里保留整页栅格。

预览与打印吃的是同一个 `PrintJob`（同一套 `PageContent` + 同一套绘制代码，只是画布多了一个缩放矩阵），
所以分页位置、折行、留白完全一致——所见即所打。改纸张或分辨率会自动重新排版并刷新预览。

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
│   │   │   ├── ZipReader.ets     内存 ZIP 读取（docx/xlsx）
│   │   │   ├── XmlParser.ets     XML 树解析（docx 富文本）
│   │   │   ├── PngDecoder.ets    PNG → RGB（Word 内嵌图片）
│   │   │   └── BmpDecoder.ets    BMP → RGB（Word 内嵌位图）
│   │   ├── pdf/                  PDF 解析 / 解释 / 生成（纯逻辑，不依赖 @kit）
│   │   ├── docx/                 Word 富文本解析 + 排版成 PDF
│   │   └── model/
│   │       ├── RasterImage.ets   RGB 位图容器
│   │       ├── PrinterConnection.ets  TCP 连接（分块发送）
│   │       ├── PrinterDiscovery.ets   mDNS 发现
│   │       ├── PageContent.ets   页面内容模型（文本/网格/图片/PDF 绘制指令）
│   │       ├── TextFont.ets      字型与字宽测量
│   │       ├── PageRenderer.ets  分带栅格化（打印）+ 整页缩略图（预览）
│   │       ├── DocumentRasterizer.ets 排版（折行/分页/表格/照片）
│   │       ├── OfficeParser.ets  xlsx XML 解析（docx 纯文字兜底仍保留）
│   │       ├── PdfPrint.ets      PDF 图像解码（JPEG 走系统解码器）
│   │       ├── EscPrEncoder.ets  ESC/P-R 编码器（核心）
│   │       └── PrintService.ets  解析(PrintSource) / 排版(PrintJob) / 预览 / 发送
│   └── resources/
├── tools/verify/verify.mjs       纯逻辑自测脚本（Node 运行，见下）
├── tools/gen/gen_pdf_metrics.py  生成 PDF 标准 14 字体度量（勿手改 PdfStdMetrics.ets）
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
ZIP 包跑完整解析链；把生成的 ESC/P-R 字节流重新解析回位图，与源位图逐像素比对；
自产 PDF 再解析抽出文字/图形并与 PyMuPDF 对拍；Word 富文本 → PDF → 再解析验证版式。

## 使用步骤

1. 手机和 L805 连**同一路由器**。
2. 点「发现」自动扫描，或在输入框手动填 IP。
3. 选纸张、质量（标准 360dpi / 高质量 720dpi）、纸张类型与色彩。
4. 点「文本 / 照片 / Word / Excel / PDF」选择内容——**此时只生成预览，不会打印**。
5. 在预览区翻页确认版式（页码、折行、留白都是实际打印效果）。
6. 确认无误后点「开始打印」；想换文件点「重新选择」。

> 预览之后再改纸张或打印质量会自动重新排版刷新预览（页数可能因此变化），
> 所以请以最后看到的预览为准。

## 各格式保真度说明（重要）

- **.txt**：单字体、单字号、左对齐的简单排版（UTF-8 编码，自动跳过 BOM）。
- **.docx**：先排版成 PDF 再打印。会保留字号、粗斜体、颜色、对齐、段间距、缩进、
  项目符号/编号、表格网格与边框、JPEG/PNG/BMP 内嵌图片。不还原的部分：页眉页脚、文本框浮于文字上、
  SmartArt/图表、嵌入字体的精确轮廓、修订/批注。复杂分栏与环绕会简化成顺序流式排版。
- **.xlsx**：渲染成**带网格线的表格**，单元格文字自动换行；不保留合并单元格、公式、图表、列宽样式；
  日期等按单元格里的原始值输出（不做数字格式化）。
- **.pdf**：按页面内容流绘制文字、矢量路径和图片，整页等比居中放到当前所选纸张上。
  支持交叉引用表/交叉引用流、对象流、损坏文件重建索引、标准 14 字体与 ToUnicode、
  Flate/LZW/ASCII85/ASCIIHex/RunLength、JPEG 与未压缩/索引图像。
  不支持：加密 PDF、JBIG2、渐变着色（sh）、Type3 字形轮廓、透明混合模式。
  文字用系统字体按 PDF 给出的位置与宽度绘制，所以中文能显示，但字形轮廓与嵌入字体不会 100% 一致。
- **照片**：等比缩放居中，横图打纵向纸时自动旋转 90°；不做 EXIF 方向校正。
- **页边距**：按爱普生喷墨机通用值取的保守值——三边 3mm，普通纸底边 14mm；
  照片纸尺寸四边 3mm。想贴边打印可以改 `common/Constants.ets` 里的 `PaperSpec`。
- 暂不支持无边距（borderless）打印与双面打印。

这些都是“内容优先”的轻量实现，达不到 WPS / Adobe / 官方驱动的排版还原度。

## PDF 说明

HarmonyOS 公开 SDK 没有 PDF 页面渲染 API，本项目用纯 ArkTS 实现了一套 PDF 解析与绘制：

- 打开文件 → 交叉引用（传统表 / xref 流 / 对象流，坏了会全文扫描重建）→ 页树；
- 解释内容流得到显示列表（文字带 PDF 自己的前进宽度、矢量路径、图像 XObject）；
- 缩放到当前打印纸的可打印区，JPEG 交给系统 `ImageKit` 解码，其余采样图像自己展开成 RGBA；
- 预览和打印共用同一份 `PageContent`。

Word 打印走「docx → 生成 PDF → 上面这条管线」，所以版式不再是纯文字。

加密 PDF 会明确报错，请先用阅读器去掉密码。

## 常见问题

- **打印失败**：界面会显示具体原因（连接失败 / 发送失败 / 文档解析失败）。
  先确认 IP 正确、同一网段、防火墙未拦 9100；可先 ping 打印机 IP。
- **发现不到打印机**：部分路由器会隔离 mDNS 组播，改用**手动输入 IP**（最稳）。
- **打印出满页乱码字符**：说明发过去的不是 ESC/P-R。本版已修；若你改过 `EscPrEncoder`，
  先跑一遍上面的自测脚本。
- **Word/Excel 打不开**：确认是标准 .docx/.xlsx（不是旧 .doc/.xls，也不能是加密文档）。
- **打印很慢**：720dpi 的 A4 一页原始数据超过 100MB，靠 RLE 压缩后仍然不小，
  Wi-Fi 传输需要时间；文字文档用 360dpi 就够了。
