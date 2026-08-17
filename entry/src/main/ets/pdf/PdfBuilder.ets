/**
 * PDF 生成器：把排好版的内容写成一个真正的 PDF 文件（字节流）。
 *
 * 用途是「Word 转 PDF 打印」——先把 .docx 排版成 PDF，再走 PDF 打印管线，
 * 这样 Word 和 PDF 走同一条渲染路径，版式（字号、粗斜体、颜色、表格、图片）
 * 不会像以前提取纯文字那样丢掉。
 *
 * 生成的是标准的、任何阅读器都能打开的 PDF 1.4 文件：
 *  - 传统 `xref` 表 + trailer（不用交叉引用流，省一套编码，兼容性也最好）；
 *  - 内容流不压缩（手机上没有现成的 deflate 压缩器，而且这个 PDF 是临时中间产物）；
 *  - 西文用标准 14 字体（Helvetica / Times / Courier + WinAnsiEncoding），不需要内嵌；
 *  - 中文用 Adobe-GB1 的 STSong-Light + UniGB-UCS2-H（预定义 CMap 的非内嵌 CJK 字体，
 *    PDF 32000-1 9.7.5.2 允许这样写），字符串按 UTF-16BE 十六进制写出；
 *  - 图片：JPEG 原样放进 DCTDecode 流（不用重新编码），其他位图按未压缩 RGB 写入。
 */

import { ByteWriter } from '../common/ByteWriter';
import { PdfStdFamily, PdfStdFonts } from './PdfStdFonts';

/** 一个待写出的间接对象 */
class PdfOutObject {
  /** 对象体（`<< ... >>` 或 `<< ... >> stream ... endstream`） */
  head: string = '';
  /** 流数据，null 表示不是流对象 */
  stream: Uint8Array | null = null;
}

/** 生成 PDF 时用到的字体标识 */
export class PdfBuiltinFont {
  /** 西文无衬线 */
  static readonly SANS: number = 0;
  /** 西文衬线 */
  static readonly SERIF: number = 1;
  /** 西文等宽 */
  static readonly MONO: number = 2;
  /** 中文（含其他非拉丁字符） */
  static readonly CJK: number = 3;

  /**
   * 由字体类别与粗斜体算出资源名，如 `F0`、`F1B`、`C0B`。
   * 资源名同时也是「同一种字体只建一个对象」的缓存键。
   */
  static resourceName(kind: number, bold: boolean, italic: boolean): string {
    let name = kind === PdfBuiltinFont.CJK ? 'C0' : 'F' + kind;
    if (bold) {
      name += 'B';
    }
    if (italic && kind !== PdfBuiltinFont.CJK) {
      name += 'I';
    }
    return name;
  }

  /** 标准 14 字体的 BaseFont 名 */
  static baseFontName(kind: number, bold: boolean, italic: boolean): string {
    if (kind === PdfBuiltinFont.CJK) {
      // 预定义 CJK 字体没有粗体变体；粗体靠 FontDescriptor 的 ForceBold 标志表达
      return 'STSong-Light';
    }
    if (kind === PdfBuiltinFont.MONO) {
      if (bold && italic) {
        return 'Courier-BoldOblique';
      }
      if (bold) {
        return 'Courier-Bold';
      }
      if (italic) {
        return 'Courier-Oblique';
      }
      return 'Courier';
    }
    if (kind === PdfBuiltinFont.SERIF) {
      if (bold && italic) {
        return 'Times-BoldItalic';
      }
      if (bold) {
        return 'Times-Bold';
      }
      if (italic) {
        return 'Times-Italic';
      }
      return 'Times-Roman';
    }
    if (bold && italic) {
      return 'Helvetica-BoldOblique';
    }
    if (bold) {
      return 'Helvetica-Bold';
    }
    if (italic) {
      return 'Helvetica-Oblique';
    }
    return 'Helvetica';
  }
}

/** 一张要写进 PDF 的图片 */
export class PdfImagePayload {
  /** 资源名，如 `Im0` */
  name: string = '';
  widthPx: number = 0;
  heightPx: number = 0;
  /** true = 数据是 JPEG，按 DCTDecode 原样放入 */
  isJpeg: boolean = false;
  /** JPEG 原始字节，或未压缩的 RGB888 数据 */
  data: Uint8Array = new Uint8Array(0);
  /** JPEG 是否为灰度（决定 ColorSpace） */
  grayscale: boolean = false;
}

/** 一页的内容与资源 */
export class PdfOutPage {
  widthPt: number = 595.28;
  heightPt: number = 841.89;
  /** 内容流文本（PDF 运算符） */
  content: string = '';
  /** 本页用到的字体资源名 */
  fonts: string[] = [];
  /** 本页用到的图片 */
  images: PdfImagePayload[] = [];
}

export class PdfBuilder {
  private readonly objects: PdfOutObject[] = [];
  /** 字体资源名 → 对象号 */
  private readonly fontObjects: Map<string, number> = new Map<string, number>();
  /** 图片资源名 → 对象号 */
  private readonly imageObjects: Map<string, number> = new Map<string, number>();
  /** CJK 字体里用到的码位 → 宽度（写 W 数组用，保证声明宽度与排版一致） */
  private readonly cjkWidths: Map<number, number> = new Map<number, number>();

  /** 预留一个对象号（1 基） */
  private reserve(): number {
    this.objects.push(new PdfOutObject());
    return this.objects.length;
  }

  /** 写入一个字典对象 */
  private putDict(num: number, body: string): void {
    this.objects[num - 1].head = body;
  }

  /** 写入一个流对象 */
  private putStream(num: number, dictBody: string, data: Uint8Array): void {
    const obj = this.objects[num - 1];
    obj.head = dictBody;
    obj.stream = data;
  }

  /** 记录一个 CJK 码位的宽度（单位 1/1000 em） */
  noteCjkCode(code: number, width: number): void {
    if (!this.cjkWidths.has(code)) {
      this.cjkWidths.set(code, width);
    }
  }

  /** 把 ASCII 文本转字节 */
  private static asciiBytes(text: string): Uint8Array {
    const out = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) {
      out[i] = text.charCodeAt(i) & 0xff;
    }
    return out;
  }

  /**
   * 组装最终 PDF。
   * @param pages 各页内容
   * @returns 完整 PDF 字节
   */
  build(pages: PdfOutPage[]): Uint8Array {
    const catalogNum = this.reserve();
    const pagesNum = this.reserve();
    const pageNums: number[] = [];
    for (let i = 0; i < pages.length; i++) {
      pageNums.push(this.reserve());
    }

    // 各页：内容流 + 资源
    for (let i = 0; i < pages.length; i++) {
      const page = pages[i];
      const contentNum = this.reserve();
      this.putStream(contentNum, '<< /Length ' + page.content.length + ' >>',
        PdfBuilder.asciiBytes(page.content));

      let fontRes = '';
      for (let k = 0; k < page.fonts.length; k++) {
        const name = page.fonts[k];
        fontRes += '/' + name + ' ' + this.fontObjectFor(name) + ' 0 R ';
      }
      let xobjRes = '';
      for (let k = 0; k < page.images.length; k++) {
        const img = page.images[k];
        xobjRes += '/' + img.name + ' ' + this.imageObjectFor(img) + ' 0 R ';
      }
      let resources = '<< /Font << ' + fontRes + '>>';
      if (xobjRes.length > 0) {
        resources += ' /XObject << ' + xobjRes + '>>';
      }
      resources += ' /ProcSet [/PDF /Text /ImageB /ImageC] >>';

      this.putDict(pageNums[i], '<< /Type /Page /Parent ' + pagesNum + ' 0 R' +
        ' /MediaBox [0 0 ' + PdfBuilder.num(page.widthPt) + ' ' + PdfBuilder.num(page.heightPt) + ']' +
        ' /Resources ' + resources +
        ' /Contents ' + contentNum + ' 0 R >>');
    }

    let kids = '';
    for (let i = 0; i < pageNums.length; i++) {
      kids += pageNums[i] + ' 0 R ';
    }
    this.putDict(pagesNum, '<< /Type /Pages /Kids [' + kids + '] /Count ' + pageNums.length + ' >>');
    this.putDict(catalogNum, '<< /Type /Catalog /Pages ' + pagesNum + ' 0 R >>');

    return this.serialize(catalogNum);
  }

  /** 取（或创建）字体对象 */
  private fontObjectFor(resourceName: string): number {
    const existing = this.fontObjects.get(resourceName);
    if (existing !== undefined) {
      return existing;
    }
    const num = this.reserve();
    this.fontObjects.set(resourceName, num);
    const bold = resourceName.indexOf('B') > 0;
    const italic = resourceName.indexOf('I') > 0;
    if (resourceName.startsWith('C')) {
      // 复合字体：Type0 + CIDFontType0 + 预定义 CMap（不内嵌字体程序）
      const descendantNum = this.reserve();
      const descriptorNum = this.reserve();
      const baseName = PdfBuiltinFont.baseFontName(PdfBuiltinFont.CJK, bold, false);
      this.putDict(num, '<< /Type /Font /Subtype /Type0 /BaseFont /' + baseName +
        ' /Encoding /UniGB-UCS2-H /DescendantFonts [' + descendantNum + ' 0 R] >>');
      // W 数组在 serialize 阶段才知道全部码位，这里先占位，稍后回填
      this.putDict(descendantNum, '@CID:' + descriptorNum + ':' + baseName);
      this.putDict(descriptorNum, '<< /Type /FontDescriptor /FontName /' + baseName +
        ' /Flags ' + (bold ? 262178 : 6) + ' /FontBBox [-25 -254 1000 880] /ItalicAngle 0' +
        ' /Ascent 880 /Descent -254 /CapHeight 731 /StemV ' + (bold ? 140 : 78) + ' >>');
      return num;
    }
    let kind = PdfBuiltinFont.SANS;
    if (resourceName.startsWith('F1')) {
      kind = PdfBuiltinFont.SERIF;
    } else if (resourceName.startsWith('F2')) {
      kind = PdfBuiltinFont.MONO;
    }
    this.putDict(num, '<< /Type /Font /Subtype /Type1 /BaseFont /' +
      PdfBuiltinFont.baseFontName(kind, bold, italic) + ' /Encoding /WinAnsiEncoding >>');
    return num;
  }

  /** 取（或创建）图片对象 */
  private imageObjectFor(image: PdfImagePayload): number {
    const existing = this.imageObjects.get(image.name);
    if (existing !== undefined) {
      return existing;
    }
    const num = this.reserve();
    this.imageObjects.set(image.name, num);
    const colorSpace = image.grayscale ? '/DeviceGray' : '/DeviceRGB';
    let dict = '<< /Type /XObject /Subtype /Image /Width ' + image.widthPx +
      ' /Height ' + image.heightPx + ' /ColorSpace ' + colorSpace +
      ' /BitsPerComponent 8';
    if (image.isJpeg) {
      dict += ' /Filter /DCTDecode';
    }
    dict += ' /Length ' + image.data.length + ' >>';
    this.putStream(num, dict, image.data);
    return num;
  }

  /** CID 字体字典（W 数组要等所有页都写完才知道用到哪些码位） */
  private cidFontDict(descriptorNum: number, baseName: string): string {
    // W 数组：`[ code [width] code [width] ... ]`，按码位升序输出
    const codes: number[] = [];
    this.cjkWidths.forEach((width: number, code: number) => {
      codes.push(code);
    });
    codes.sort((a: number, b: number) => a - b);
    let w = '';
    for (let i = 0; i < codes.length; i++) {
      const width = this.cjkWidths.get(codes[i]);
      if (width !== undefined && width !== 1000) {
        w += codes[i] + '[' + PdfBuilder.num(width) + ']';
      }
    }
    let dict = '<< /Type /Font /Subtype /CIDFontType0 /BaseFont /' + baseName +
      ' /CIDSystemInfo << /Registry (Adobe) /Ordering (GB1) /Supplement 2 >>' +
      ' /FontDescriptor ' + descriptorNum + ' 0 R /DW 1000';
    if (w.length > 0) {
      dict += ' /W [' + w + ']';
    }
    dict += ' >>';
    return dict;
  }

  /** 数字格式化：最多两位小数，去掉多余的 0（PDF 体积友好） */
  static num(value: number): string {
    if (!(value === value)) {
      return '0'; // NaN 保护
    }
    const rounded = Math.round(value * 100) / 100;
    if (rounded === Math.trunc(rounded)) {
      return '' + Math.trunc(rounded);
    }
    let s = '' + rounded;
    // ArkTS 的数字转字符串不会给出指数形式（这里的值域是页面坐标），直接返回
    return s;
  }

  /** 把对象表写成 PDF 文件 */
  private serialize(catalogNum: number): Uint8Array {
    const w = new ByteWriter(256 * 1024);
    w.writeAscii('%PDF-1.4\n');
    // 二进制标记注释：告诉工具这是二进制文件
    w.writeByte(0x25);
    w.writeByte(0xe2);
    w.writeByte(0xe3);
    w.writeByte(0xcf);
    w.writeByte(0xd3);
    w.writeByte(0x0a);

    const offsets: number[] = [];
    for (let i = 0; i < this.objects.length; i++) {
      const obj = this.objects[i];
      offsets.push(w.length);
      let head = obj.head;
      if (head.startsWith('@CID:')) {
        // 回填 CID 字体字典（此时 cjkWidths 已收集完）
        const parts = head.split(':');
        head = this.cidFontDict(PdfBuilder.parseDec(parts[1]), parts[2]);
      }
      if (head.length === 0) {
        head = '<< >>';
      }
      w.writeAscii('' + (i + 1) + ' 0 obj\n');
      w.writeAscii(head);
      if (obj.stream !== null) {
        w.writeAscii('\nstream\n');
        w.writeBytes(obj.stream);
        w.writeAscii('\nendstream');
      }
      w.writeAscii('\nendobj\n');
    }

    const xrefOffset = w.length;
    w.writeAscii('xref\n0 ' + (this.objects.length + 1) + '\n');
    w.writeAscii('0000000000 65535 f \n');
    for (let i = 0; i < offsets.length; i++) {
      w.writeAscii(PdfBuilder.pad10(offsets[i]) + ' 00000 n \n');
    }
    w.writeAscii('trailer\n<< /Size ' + (this.objects.length + 1) +
      ' /Root ' + catalogNum + ' 0 R >>\nstartxref\n' + xrefOffset + '\n%%EOF\n');
    return w.toBytes();
  }

  /** 交叉引用表的偏移字段固定 10 位 */
  private static pad10(value: number): string {
    let s = '' + Math.trunc(value);
    while (s.length < 10) {
      s = '0' + s;
    }
    return s;
  }

  /**
   * 把一段文本编码成 PDF 字符串字面量（十六进制形式）。
   *
   * @param text 文本
   * @param cjk true 表示写成 UTF-16BE（供 UniGB-UCS2-H 的 CJK 字体使用），
   *            false 表示写成 WinAnsi 单字节
   */
  static hexString(text: string, cjk: boolean): string {
    let out = '<';
    for (let i = 0; i < text.length; i++) {
      const code = text.charCodeAt(i);
      if (cjk) {
        out += PdfBuilder.hex2((code >> 8) & 0xff) + PdfBuilder.hex2(code & 0xff);
      } else {
        out += PdfBuilder.hex2(PdfBuilder.toWinAnsi(code));
      }
    }
    return out + '>';
  }

  private static hex2(v: number): string {
    const digits = '0123456789ABCDEF';
    return digits.charAt((v >> 4) & 0x0f) + digits.charAt(v & 0x0f);
  }

  /** Unicode → WinAnsi 字节（映射不到时退化成 '?'） */
  static toWinAnsi(code: number): number {
    if (code >= 0x20 && code <= 0x7e) {
      return code;
    }
    if (code >= 0xa0 && code <= 0xff) {
      return code;
    }
    // WinAnsi 的 0x80~0x9F 是一批特殊标点
    if (code === 0x20ac) {
      return 0x80;
    }
    if (code === 0x201a) {
      return 0x82;
    }
    if (code === 0x0192) {
      return 0x83;
    }
    if (code === 0x201e) {
      return 0x84;
    }
    if (code === 0x2026) {
      return 0x85;
    }
    if (code === 0x2020) {
      return 0x86;
    }
    if (code === 0x2021) {
      return 0x87;
    }
    if (code === 0x02c6) {
      return 0x88;
    }
    if (code === 0x2030) {
      return 0x89;
    }
    if (code === 0x0160) {
      return 0x8a;
    }
    if (code === 0x2039) {
      return 0x8b;
    }
    if (code === 0x0152) {
      return 0x8c;
    }
    if (code === 0x2018) {
      return 0x91;
    }
    if (code === 0x2019) {
      return 0x92;
    }
    if (code === 0x201c) {
      return 0x93;
    }
    if (code === 0x201d) {
      return 0x94;
    }
    if (code === 0x2022) {
      return 0x95;
    }
    if (code === 0x2013) {
      return 0x96;
    }
    if (code === 0x2014) {
      return 0x97;
    }
    if (code === 0x02dc) {
      return 0x98;
    }
    if (code === 0x2122) {
      return 0x99;
    }
    if (code === 0x0161) {
      return 0x9a;
    }
    if (code === 0x203a) {
      return 0x9b;
    }
    if (code === 0x0153) {
      return 0x9c;
    }
    if (code === 0x0178) {
      return 0x9f;
    }
    return 0x3f; // '?'
  }

  /**
   * 判断一个字符是否能用西文标准字体（WinAnsi）表示。
   * 不能表示的（中文、日文、希腊文、西里尔文等）走 CJK 字体，
   * 它用 UniGB-UCS2-H 编码，任何 BMP 字符都能写进去。
   */
  static isWinAnsiChar(code: number): boolean {
    if (code >= 0x20 && code <= 0x7e) {
      return true;
    }
    if (code >= 0xa0 && code <= 0xff) {
      return true;
    }
    return PdfBuilder.toWinAnsi(code) !== 0x3f;
  }

  /** 解析十进制整数（回填 CID 字体字典时用） */
  private static parseDec(text: string): number {
    let v = 0;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if (c < 0x30 || c > 0x39) {
        break;
      }
      v = v * 10 + (c - 0x30);
    }
    return v;
  }

  /** 标准 14 字体的字宽（单位 1/1000 em），用于排版时测量西文 */
  static latinWidth(kind: number, bold: boolean, italic: boolean, code: number): number {
    if (kind === PdfBuiltinFont.MONO) {
      return 600;
    }
    const family = kind === PdfBuiltinFont.SERIF ? PdfStdFamily.TIMES : PdfStdFamily.HELVETICA;
    const encoding = PdfStdFonts.encoding('WinAnsiEncoding');
    const byte = PdfBuilder.toWinAnsi(code);
    const glyphName = byte < 256 ? encoding[byte] : '';
    if (glyphName.length === 0) {
      return 500;
    }
    const w = PdfStdFonts.glyphWidth(family, bold, italic, glyphName);
    return w >= 0 ? w : 500;
  }
}
