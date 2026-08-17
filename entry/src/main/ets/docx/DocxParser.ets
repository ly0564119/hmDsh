/**
 * .docx 解析：ZIP 包 → 富文本模型（DocxDocument）。
 *
 * 读取的部件：
 *  - `word/document.xml`：正文（段落、表格、图片引用、节属性）；
 *  - `word/styles.xml`：文档默认格式 + 段落/字符样式（含 basedOn 继承链）；
 *  - `word/numbering.xml`：编号与项目符号（取列表前缀与缩进）；
 *  - `word/_rels/document.xml.rels`：图片关系 ID → `word/media/...`；
 *  - `word/media/*`：图片原始字节。
 *
 * 与旧版「只提取纯文字」的区别：这里保留了字号、粗斜体、颜色、对齐、缩进、
 * 段间距、表格网格与边框、内嵌图片，后面 DocxToPdf 才能排出接近 Word 的版式。
 */

import { ZipArchive } from '../common/ZipReader';
import { XmlNode, XmlParser } from '../common/XmlParser';
import { PngDecoder } from '../common/PngDecoder';
import { BmpDecoder } from '../common/BmpDecoder';
import {
  DocxAlign,
  DocxBlock,
  DocxBorders,
  DocxCell,
  DocxDocument,
  DocxImage,
  DocxParagraph,
  DocxParaStyle,
  DocxRow,
  DocxRun,
  DocxRunStyle,
  DocxSection,
  DocxTable,
  DocxUnits
} from './DocxModel';

/** 一个命名样式（段落样式或字符样式） */
class DocxStyle {
  id: string = '';
  basedOn: string = '';
  /** 样式类型：paragraph / character / table */
  type: string = '';
  para: DocxParaStyle | null = null;
  run: DocxRunStyle | null = null;
  /** 大纲级别 + 1（0 表示未指定） */
  outlineLevel: number = 0;
  /** 关联的编号定义 */
  numId: string = '';
  numLevel: number = 0;
}

/** 一个编号级别的定义 */
class DocxNumLevel {
  /** decimal / bullet / lowerLetter / upperRoman ... */
  format: string = 'decimal';
  /** 形如 `%1.`、`%1.%2` 的模板 */
  text: string = '';
  indentLeftPt: number = 0;
  indentFirstPt: number = 0;
  /** 项目符号用的字体（Symbol / Wingdings 里的私用区字符要换成通用符号） */
  fontName: string = '';
}

export class DocxParser {
  private readonly archive: ZipArchive;
  /** 样式表 */
  private readonly styles: Map<string, DocxStyle> = new Map<string, DocxStyle>();
  /** 文档默认字符格式 */
  private defaultRun: DocxRunStyle = new DocxRunStyle();
  /** 文档默认段落格式 */
  private defaultPara: DocxParaStyle = new DocxParaStyle();
  /** 关系 ID → 部件路径 */
  private readonly rels: Map<string, string> = new Map<string, string>();
  /** numId → (级别 → 定义) */
  private readonly numbering: Map<string, Map<number, DocxNumLevel>> = new Map<string, Map<number, DocxNumLevel>>();
  /** 编号计数器：`numId:level` → 当前值 */
  private readonly counters: Map<string, number> = new Map<string, number>();
  /** 图片缓存：部件路径 → 图片字节 */
  private readonly mediaCache: Map<string, Uint8Array> = new Map<string, Uint8Array>();

  private constructor(archive: ZipArchive) {
    this.archive = archive;
  }

  /**
   * 解析一个 .docx。
   * @throws 不是标准 docx 时抛出带中文说明的错误
   */
  static parse(data: Uint8Array): DocxDocument {
    const archive = ZipArchive.open(data);
    const parser = new DocxParser(archive);
    return parser.run();
  }

  private run(): DocxDocument {
    let bodyPath = 'word/document.xml';
    if (!this.archive.has(bodyPath)) {
      bodyPath = this.archive.findByPrefixSuffix('word/document', '.xml');
      if (bodyPath.length === 0) {
        throw new Error('这不是标准 .docx（缺少 word/document.xml），请用 Word 另存为 .docx');
      }
    }
    this.loadStyles();
    this.loadNumbering();
    this.loadRels();

    const doc = new DocxDocument();
    const root = XmlParser.parse(this.archive.readText(bodyPath));
    const body = root.child('w:body');
    if (body === null) {
      throw new Error('Word 文档正文为空');
    }
    for (let i = 0; i < body.children.length; i++) {
      const node = body.children[i];
      const name = node.localName;
      if (name === 'p') {
        doc.blocks.push(this.parseParagraph(node));
      } else if (name === 'tbl') {
        doc.blocks.push(this.parseTable(node));
      } else if (name === 'sectPr') {
        doc.section = DocxParser.parseSection(node);
      }
    }
    return doc;
  }

  /** 读 styles.xml：docDefaults + 各命名样式 */
  private loadStyles(): void {
    if (!this.archive.has('word/styles.xml')) {
      return;
    }
    const root = XmlParser.parse(this.archive.readText('word/styles.xml'));
    const docDefaults = root.child('w:docDefaults');
    if (docDefaults !== null) {
      const rPrDefault = docDefaults.path(['w:rPrDefault', 'w:rPr']);
      if (rPrDefault !== null) {
        this.applyRunProps(rPrDefault, this.defaultRun);
      }
      const pPrDefault = docDefaults.path(['w:pPrDefault', 'w:pPr']);
      if (pPrDefault !== null) {
        this.applyParaProps(pPrDefault, this.defaultPara);
      }
    }
    const styleNodes = root.childrenNamed('w:style');
    for (let i = 0; i < styleNodes.length; i++) {
      const node = styleNodes[i];
      const style = new DocxStyle();
      style.id = node.attr('w:styleId');
      style.type = node.attr('w:type');
      style.basedOn = node.childVal('w:basedOn');
      const pPr = node.child('w:pPr');
      if (pPr !== null) {
        const para = new DocxParaStyle();
        this.applyParaProps(pPr, para);
        style.para = para;
        const outline = pPr.child('w:outlineLvl');
        if (outline !== null) {
          style.outlineLevel = DocxParser.parseNum(outline.attr('w:val'), -1) + 1;
        }
        const numPr = pPr.child('w:numPr');
        if (numPr !== null) {
          style.numId = numPr.childVal('w:numId');
          style.numLevel = Math.trunc(DocxParser.parseNum(numPr.childVal('w:ilvl'), 0));
        }
      }
      const rPr = node.child('w:rPr');
      if (rPr !== null) {
        const run = new DocxRunStyle();
        this.applyRunProps(rPr, run);
        style.run = run;
      }
      if (style.id.length > 0) {
        this.styles.set(style.id, style);
      }
    }
  }

  /** 读 numbering.xml */
  private loadNumbering(): void {
    if (!this.archive.has('word/numbering.xml')) {
      return;
    }
    const root = XmlParser.parse(this.archive.readText('word/numbering.xml'));
    // abstractNumId → 级别定义
    const abstracts = new Map<string, Map<number, DocxNumLevel>>();
    const abstractNodes = root.childrenNamed('w:abstractNum');
    for (let i = 0; i < abstractNodes.length; i++) {
      const node = abstractNodes[i];
      const id = node.attr('w:abstractNumId');
      const levels = new Map<number, DocxNumLevel>();
      const lvlNodes = node.childrenNamed('w:lvl');
      for (let k = 0; k < lvlNodes.length; k++) {
        const lvlNode = lvlNodes[k];
        const level = Math.trunc(DocxParser.parseNum(lvlNode.attr('w:ilvl'), 0));
        const def = new DocxNumLevel();
        const fmt = lvlNode.childVal('w:numFmt');
        if (fmt.length > 0) {
          def.format = fmt;
        }
        def.text = lvlNode.childVal('w:lvlText');
        const rFonts = lvlNode.path(['w:rPr', 'w:rFonts']);
        if (rFonts !== null) {
          def.fontName = rFonts.attr('w:ascii');
        }
        const ind = lvlNode.path(['w:pPr', 'w:ind']);
        if (ind !== null) {
          def.indentLeftPt = DocxUnits.twipToPt(DocxParser.parseNum(ind.attr('w:left'), 0));
          const hanging = DocxParser.parseNum(ind.attr('w:hanging'), 0);
          if (hanging > 0) {
            def.indentFirstPt = -DocxUnits.twipToPt(hanging);
          } else {
            def.indentFirstPt = DocxUnits.twipToPt(DocxParser.parseNum(ind.attr('w:firstLine'), 0));
          }
        }
        levels.set(level, def);
      }
      abstracts.set(id, levels);
    }
    // num → abstractNum
    const numNodes = root.childrenNamed('w:num');
    for (let i = 0; i < numNodes.length; i++) {
      const node = numNodes[i];
      const numId = node.attr('w:numId');
      const abstractId = node.childVal('w:abstractNumId');
      const levels = abstracts.get(abstractId);
      if (levels !== undefined) {
        this.numbering.set(numId, levels);
      }
    }
  }

  /** 读 document.xml.rels */
  private loadRels(): void {
    const path = 'word/_rels/document.xml.rels';
    if (!this.archive.has(path)) {
      return;
    }
    const root = XmlParser.parse(this.archive.readText(path));
    const nodes = root.childrenNamed('Relationship');
    for (let i = 0; i < nodes.length; i++) {
      const id = nodes[i].attr('Id');
      let target = nodes[i].attr('Target');
      if (id.length === 0 || target.length === 0) {
        continue;
      }
      if (target.startsWith('/')) {
        target = target.substring(1);
      } else if (!target.startsWith('word/')) {
        target = 'word/' + target;
      }
      // 规范化 `word/../media/x.png` 这类相对路径
      this.rels.set(id, DocxParser.normalizePath(target));
    }
  }

  /** 折叠路径里的 `..` 与 `.` */
  private static normalizePath(path: string): string {
    const parts = path.split('/');
    const out: string[] = [];
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      if (p === '.' || p.length === 0) {
        continue;
      }
      if (p === '..') {
        if (out.length > 0) {
          out.pop();
        }
        continue;
      }
      out.push(p);
    }
    return out.join('/');
  }

  /** 解析 sectPr：纸张与页边距 */
  private static parseSection(node: XmlNode): DocxSection {
    const section = new DocxSection();
    const pgSz = node.child('w:pgSz');
    if (pgSz !== null) {
      const w = DocxParser.parseNum(pgSz.attr('w:w'), 0);
      const h = DocxParser.parseNum(pgSz.attr('w:h'), 0);
      if (w > 0 && h > 0) {
        section.widthPt = DocxUnits.twipToPt(w);
        section.heightPt = DocxUnits.twipToPt(h);
      }
    }
    const pgMar = node.child('w:pgMar');
    if (pgMar !== null) {
      section.marginLeftPt = DocxUnits.twipToPt(DocxParser.parseNum(pgMar.attr('w:left'), 1800));
      section.marginRightPt = DocxUnits.twipToPt(DocxParser.parseNum(pgMar.attr('w:right'), 1800));
      section.marginTopPt = DocxUnits.twipToPt(DocxParser.parseNum(pgMar.attr('w:top'), 1440));
      section.marginBottomPt = DocxUnits.twipToPt(DocxParser.parseNum(pgMar.attr('w:bottom'), 1440));
    }
    return section;
  }

  /** 沿 basedOn 链把样式叠加到给定的格式上（先父后子） */
  private applyStyleChain(styleId: string, para: DocxParaStyle | null,
    run: DocxRunStyle | null, depth: number): number {
    if (styleId.length === 0 || depth > 10) {
      return 0;
    }
    const style = this.styles.get(styleId);
    if (style === undefined) {
      return 0;
    }
    let outline = this.applyStyleChain(style.basedOn, para, run, depth + 1);
    if (para !== null && style.para !== null) {
      DocxParser.mergePara(style.para, para);
    }
    if (run !== null && style.run !== null) {
      DocxParser.mergeRun(style.run, run);
    }
    if (style.outlineLevel > 0) {
      outline = style.outlineLevel;
    }
    return outline;
  }

  /** 把 src 里「非默认」的段落属性合并到 dst */
  private static mergePara(src: DocxParaStyle, dst: DocxParaStyle): void {
    dst.align = src.align;
    dst.indentLeftPt = src.indentLeftPt;
    dst.indentRightPt = src.indentRightPt;
    dst.indentFirstPt = src.indentFirstPt;
    dst.spaceBeforePt = src.spaceBeforePt;
    dst.spaceAfterPt = src.spaceAfterPt;
    dst.lineMultiple = src.lineMultiple;
    dst.lineExactPt = src.lineExactPt;
  }

  /** 把 src 的字符属性合并到 dst */
  private static mergeRun(src: DocxRunStyle, dst: DocxRunStyle): void {
    dst.bold = src.bold;
    dst.italic = src.italic;
    dst.underline = src.underline;
    dst.strike = src.strike;
    dst.sizePt = src.sizePt;
    dst.color = src.color;
    dst.serif = src.serif;
    dst.mono = src.mono;
    dst.vertAlign = src.vertAlign;
    dst.highlight = src.highlight;
  }

  /** 解析 w:pPr 到段落格式 */
  private applyParaProps(pPr: XmlNode, style: DocxParaStyle): void {
    const jc = pPr.childVal('w:jc');
    if (jc === 'center') {
      style.align = DocxAlign.CENTER;
    } else if (jc === 'right' || jc === 'end') {
      style.align = DocxAlign.RIGHT;
    } else if (jc === 'both' || jc === 'distribute') {
      style.align = DocxAlign.JUSTIFY;
    } else if (jc === 'left' || jc === 'start') {
      style.align = DocxAlign.LEFT;
    }
    const ind = pPr.child('w:ind');
    if (ind !== null) {
      if (ind.hasAttr('w:left') || ind.hasAttr('w:start')) {
        const left = ind.hasAttr('w:left') ? ind.attr('w:left') : ind.attr('w:start');
        style.indentLeftPt = DocxUnits.twipToPt(DocxParser.parseNum(left, 0));
      }
      if (ind.hasAttr('w:right') || ind.hasAttr('w:end')) {
        const right = ind.hasAttr('w:right') ? ind.attr('w:right') : ind.attr('w:end');
        style.indentRightPt = DocxUnits.twipToPt(DocxParser.parseNum(right, 0));
      }
      if (ind.hasAttr('w:hanging')) {
        style.indentFirstPt = -DocxUnits.twipToPt(DocxParser.parseNum(ind.attr('w:hanging'), 0));
      } else if (ind.hasAttr('w:firstLine')) {
        style.indentFirstPt = DocxUnits.twipToPt(DocxParser.parseNum(ind.attr('w:firstLine'), 0));
      } else if (ind.hasAttr('w:firstLineChars')) {
        // 按字符数缩进：1 个字符 ≈ 当前字号，这里按 100 分之一字符单位换算
        style.indentFirstPt = DocxParser.parseNum(ind.attr('w:firstLineChars'), 0) / 100 * 10.5;
      }
    }
    const spacing = pPr.child('w:spacing');
    if (spacing !== null) {
      if (spacing.hasAttr('w:before')) {
        style.spaceBeforePt = DocxUnits.twipToPt(DocxParser.parseNum(spacing.attr('w:before'), 0));
      }
      if (spacing.hasAttr('w:after')) {
        style.spaceAfterPt = DocxUnits.twipToPt(DocxParser.parseNum(spacing.attr('w:after'), 0));
      }
      if (spacing.hasAttr('w:line')) {
        const line = DocxParser.parseNum(spacing.attr('w:line'), 240);
        const rule = spacing.attr('w:lineRule');
        if (rule === 'exact' || rule === 'atLeast') {
          style.lineExactPt = DocxUnits.twipToPt(line);
          style.lineMultiple = 1;
        } else {
          // auto：240 缇 = 单倍行距
          style.lineMultiple = line / 240;
          style.lineExactPt = 0;
        }
      }
    }
  }

  /** 解析 w:rPr 到字符格式 */
  private applyRunProps(rPr: XmlNode, style: DocxRunStyle): void {
    if (DocxParser.onOff(rPr, 'w:b')) {
      style.bold = true;
    } else if (DocxParser.offExplicit(rPr, 'w:b')) {
      style.bold = false;
    }
    if (DocxParser.onOff(rPr, 'w:i')) {
      style.italic = true;
    } else if (DocxParser.offExplicit(rPr, 'w:i')) {
      style.italic = false;
    }
    const u = rPr.child('w:u');
    if (u !== null) {
      const val = u.attr('w:val');
      style.underline = val.length === 0 ? true : val !== 'none';
    }
    if (DocxParser.onOff(rPr, 'w:strike')) {
      style.strike = true;
    }
    const sz = rPr.child('w:sz');
    if (sz !== null) {
      const half = DocxParser.parseNum(sz.attr('w:val'), 0);
      if (half > 0) {
        style.sizePt = DocxUnits.halfPointToPt(half);
      }
    }
    const color = rPr.child('w:color');
    if (color !== null) {
      const rgb = DocxParser.parseColor(color.attr('w:val'));
      if (rgb >= 0) {
        style.color = rgb;
      }
    }
    const highlight = rPr.child('w:highlight');
    if (highlight !== null) {
      style.highlight = DocxParser.namedColor(highlight.attr('w:val'));
    }
    const shd = rPr.child('w:shd');
    if (shd !== null) {
      const fill = DocxParser.parseColor(shd.attr('w:fill'));
      if (fill >= 0) {
        style.highlight = fill;
      }
    }
    const rFonts = rPr.child('w:rFonts');
    if (rFonts !== null) {
      let name = rFonts.attr('w:ascii');
      if (name.length === 0) {
        name = rFonts.attr('w:eastAsia');
      }
      if (name.length === 0) {
        name = rFonts.attr('w:hAnsi');
      }
      if (name.length > 0) {
        style.serif = DocxParser.isSerifFont(name);
        style.mono = DocxParser.isMonoFont(name);
      }
    }
    const vertAlign = rPr.childVal('w:vertAlign');
    if (vertAlign === 'superscript') {
      style.vertAlign = 1;
    } else if (vertAlign === 'subscript') {
      style.vertAlign = 2;
    }
  }

  /** OOXML 的开关属性：`<w:b/>` 或 `<w:b w:val="1"/>` 都算开 */
  private static onOff(parent: XmlNode, name: string): boolean {
    const node = parent.child(name);
    if (node === null) {
      return false;
    }
    const val = node.attr('w:val');
    return val.length === 0 || val === '1' || val === 'true' || val === 'on';
  }

  /** 显式关闭（`w:val="0"`），用于覆盖样式里的开 */
  private static offExplicit(parent: XmlNode, name: string): boolean {
    const node = parent.child(name);
    if (node === null) {
      return false;
    }
    const val = node.attr('w:val');
    return val === '0' || val === 'false' || val === 'off';
  }

  /** 字体名 → 是否衬线（中文宋体、西文 Times 类算衬线） */
  private static isSerifFont(name: string): boolean {
    const lower = name.toLowerCase();
    if (lower.indexOf('hei') >= 0 || lower.indexOf('黑') >= 0 || lower.indexOf('yahei') >= 0 ||
      lower.indexOf('arial') >= 0 || lower.indexOf('helvetica') >= 0 ||
      lower.indexOf('calibri') >= 0 || lower.indexOf('tahoma') >= 0 ||
      lower.indexOf('verdana') >= 0 || lower.indexOf('gothic') >= 0 ||
      lower.indexOf('sans') >= 0 || lower.indexOf('圆') >= 0) {
      return false;
    }
    return true;
  }

  /** 字体名 → 是否等宽 */
  private static isMonoFont(name: string): boolean {
    const lower = name.toLowerCase();
    return lower.indexOf('courier') >= 0 || lower.indexOf('consolas') >= 0 ||
      lower.indexOf('mono') >= 0 || lower.indexOf('code') >= 0;
  }

  /** `RRGGBB` 十六进制颜色，auto/空返回 -1 */
  private static parseColor(text: string): number {
    if (text.length !== 6) {
      return DocxParser.namedColor(text);
    }
    let v = 0;
    for (let i = 0; i < 6; i++) {
      const c = text.charCodeAt(i);
      let d = -1;
      if (c >= 0x30 && c <= 0x39) {
        d = c - 0x30;
      } else if (c >= 0x41 && c <= 0x46) {
        d = c - 0x41 + 10;
      } else if (c >= 0x61 && c <= 0x66) {
        d = c - 0x61 + 10;
      } else {
        return -1;
      }
      v = v * 16 + d;
    }
    return v;
  }

  /** Word 的命名颜色（高亮用得多） */
  private static namedColor(name: string): number {
    if (name === 'yellow') {
      return 0xffff00;
    }
    if (name === 'green') {
      return 0x00ff00;
    }
    if (name === 'cyan') {
      return 0x00ffff;
    }
    if (name === 'magenta') {
      return 0xff00ff;
    }
    if (name === 'red') {
      return 0xff0000;
    }
    if (name === 'blue') {
      return 0x0000ff;
    }
    if (name === 'darkGray' || name === 'gray') {
      return 0x808080;
    }
    if (name === 'lightGray') {
      return 0xd3d3d3;
    }
    if (name === 'black') {
      return 0x000000;
    }
    if (name === 'white') {
      return 0xffffff;
    }
    return -1;
  }

  /** 数字属性解析（支持负号） */
  private static parseNum(text: string, fallback: number): number {
    if (text.length === 0) {
      return fallback;
    }
    let sign = 1;
    let i = 0;
    if (text.charAt(0) === '-') {
      sign = -1;
      i = 1;
    } else if (text.charAt(0) === '+') {
      i = 1;
    }
    let v = 0;
    let digits = 0;
    let frac = 0;
    let fracScale = 1;
    let inFrac = false;
    for (; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if (c === 0x2e) {
        inFrac = true;
        continue;
      }
      if (c < 0x30 || c > 0x39) {
        break;
      }
      if (inFrac) {
        fracScale *= 10;
        frac = frac * 10 + (c - 0x30);
      } else {
        v = v * 10 + (c - 0x30);
      }
      digits++;
    }
    if (digits === 0) {
      return fallback;
    }
    return sign * (v + frac / fracScale);
  }

  /** 解析一个段落 */
  private parseParagraph(node: XmlNode): DocxParagraph {
    const para = new DocxParagraph();
    para.style = this.defaultPara.clone();
    const baseRun = this.defaultRun.clone();

    const pPr = node.child('w:pPr');
    let styleId = '';
    if (pPr !== null) {
      styleId = pPr.childVal('w:pStyle');
    }
    // 段落样式（含 basedOn 链）
    const outline = this.applyStyleChain(styleId, para.style, baseRun, 0);
    para.outlineLevel = outline;
    let numId = '';
    let numLevel = 0;
    const styleDef = this.styles.get(styleId);
    if (styleDef !== undefined && styleDef.numId.length > 0) {
      numId = styleDef.numId;
      numLevel = styleDef.numLevel;
    }

    if (pPr !== null) {
      this.applyParaProps(pPr, para.style);
      const outlineNode = pPr.child('w:outlineLvl');
      if (outlineNode !== null) {
        para.outlineLevel = Math.trunc(DocxParser.parseNum(outlineNode.attr('w:val'), -1)) + 1;
      }
      const numPr = pPr.child('w:numPr');
      if (numPr !== null) {
        const id = numPr.childVal('w:numId');
        if (id.length > 0) {
          numId = id;
          numLevel = Math.trunc(DocxParser.parseNum(numPr.childVal('w:ilvl'), 0));
        }
      }
      // 段落级字符格式（影响整段，比如整段加粗的标题）
      const paraRPr = pPr.child('w:rPr');
      if (paraRPr !== null) {
        this.applyRunProps(paraRPr, baseRun);
      }
    }

    if (numId.length > 0 && numId !== '0') {
      this.applyNumbering(para, numId, numLevel, baseRun);
    }

    this.collectRuns(node, baseRun, para.runs, 0);
    return para;
  }

  /** 给段落加上列表前缀与缩进 */
  private applyNumbering(para: DocxParagraph, numId: string, level: number,
    baseRun: DocxRunStyle): void {
    const levels = this.numbering.get(numId);
    if (levels === undefined) {
      return;
    }
    const def = levels.get(level);
    if (def === undefined) {
      return;
    }
    if (def.indentLeftPt > 0) {
      para.style.indentLeftPt = def.indentLeftPt;
      para.style.indentFirstPt = def.indentFirstPt;
    }
    para.bulletStyle = baseRun.clone();
    if (def.format === 'bullet') {
      para.bullet = DocxParser.bulletChar(level);
      return;
    }
    if (def.format === 'none') {
      return;
    }
    // 计数：同级别 +1，并把更深层级的计数清零
    const key = numId + ':' + level;
    const current = this.counters.get(key);
    const next = current === undefined ? 1 : current + 1;
    this.counters.set(key, next);
    for (let deeper = level + 1; deeper < 9; deeper++) {
      this.counters.delete(numId + ':' + deeper);
    }
    let template = def.text.length > 0 ? def.text : '%' + (level + 1) + '.';
    for (let l = 0; l < 9; l++) {
      const placeholder = '%' + (l + 1);
      if (template.indexOf(placeholder) < 0) {
        continue;
      }
      const value = l === level ? next : (this.counters.get(numId + ':' + l) === undefined
        ? 1 : (this.counters.get(numId + ':' + l) as number));
      const levelDef = levels.get(l);
      const fmt = l === level ? def.format : (levelDef === undefined ? 'decimal' : levelDef.format);
      template = template.split(placeholder).join(DocxParser.formatNumber(value, fmt));
    }
    para.bullet = template;
  }

  /** 各层级项目符号（Symbol / Wingdings 字符统一换成通用符号） */
  private static bulletChar(level: number): string {
    const mod = level % 3;
    if (mod === 1) {
      return '○';
    }
    if (mod === 2) {
      return '▪';
    }
    return '•';
  }

  /** 编号格式化 */
  private static formatNumber(value: number, format: string): string {
    if (format === 'lowerLetter') {
      return DocxParser.toLetter(value, 97);
    }
    if (format === 'upperLetter') {
      return DocxParser.toLetter(value, 65);
    }
    if (format === 'lowerRoman') {
      return DocxParser.toRoman(value).toLowerCase();
    }
    if (format === 'upperRoman') {
      return DocxParser.toRoman(value);
    }
    if (format === 'chineseCounting' || format === 'chineseCountingThousand') {
      return DocxParser.toChinese(value);
    }
    if (format === 'decimalEnclosedCircle') {
      if (value >= 1 && value <= 20) {
        return String.fromCharCode(0x2460 + value - 1);
      }
      return '' + value;
    }
    return '' + Math.trunc(value);
  }

  private static toLetter(value: number, base: number): string {
    let n = Math.max(1, Math.trunc(value));
    let out = '';
    while (n > 0) {
      const rem = (n - 1) % 26;
      out = String.fromCharCode(base + rem) + out;
      n = Math.floor((n - 1) / 26);
    }
    return out;
  }

  private static toRoman(value: number): string {
    let n = Math.max(1, Math.trunc(value));
    const values: number[] = [1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1];
    const symbols: string[] = ['M', 'CM', 'D', 'CD', 'C', 'XC', 'L', 'XL', 'X', 'IX', 'V', 'IV', 'I'];
    let out = '';
    for (let i = 0; i < values.length; i++) {
      while (n >= values[i]) {
        out += symbols[i];
        n -= values[i];
      }
    }
    return out;
  }

  /** 中文数字（一、二、……，只覆盖常见的 1~99） */
  private static toChinese(value: number): string {
    const digits: string[] = ['零', '一', '二', '三', '四', '五', '六', '七', '八', '九'];
    const n = Math.trunc(value);
    if (n <= 0) {
      return '' + n;
    }
    if (n < 10) {
      return digits[n];
    }
    if (n < 20) {
      return n === 10 ? '十' : '十' + digits[n - 10];
    }
    if (n < 100) {
      const tens = Math.floor(n / 10);
      const ones = n % 10;
      return digits[tens] + '十' + (ones === 0 ? '' : digits[ones]);
    }
    return '' + n;
  }

  /**
   * 递归收集段落里的所有 run。
   * 超链接（w:hyperlink）、智能标签、修订插入（w:ins）里的 run 也要收进来。
   */
  private collectRuns(node: XmlNode, baseStyle: DocxRunStyle, out: DocxRun[], depth: number): void {
    if (depth > 24) {
      return;
    }
    for (let i = 0; i < node.children.length; i++) {
      const child = node.children[i];
      const name = child.localName;
      if (name === 'r') {
        this.parseRun(child, baseStyle, out);
        continue;
      }
      if (name === 'drawing' || name === 'pict' || name === 'object') {
        const image = this.parseImage(child);
        if (image !== null) {
          const run = new DocxRun();
          run.style = baseStyle.clone();
          run.image = image;
          out.push(run);
        }
        continue;
      }
      if (name === 'hyperlink' || name === 'ins' || name === 'smartTag' || name === 'sdt' ||
        name === 'sdtContent' || name === 'bookmarkStart' || name === 'fldSimple') {
        this.collectRuns(child, baseStyle, out, depth + 1);
        continue;
      }
      if (name === 'AlternateContent') {
        this.collectAlternate(child, baseStyle, out, depth + 1);
        continue;
      }
      if (name === 'del' || name === 'pPr' || name === 'rPr') {
        continue; // 删除的修订内容不打印
      }
      if (child.children.length > 0) {
        this.collectRuns(child, baseStyle, out, depth + 1);
      }
    }
  }

  /**
   * mc:AlternateContent：优先走 mc:Choice（DrawingML），没有再走 VML Fallback。
   * 两个都挖会把同一张图解析两遍。
   */
  private collectAlternate(node: XmlNode, baseStyle: DocxRunStyle, out: DocxRun[], depth: number): void {
    const choice = node.child('Choice');
    if (choice !== null) {
      this.collectRuns(choice, baseStyle, out, depth);
      return;
    }
    const fallback = node.child('Fallback');
    if (fallback !== null) {
      this.collectRuns(fallback, baseStyle, out, depth);
    }
  }

  /** 解析一个 run */
  private parseRun(node: XmlNode, baseStyle: DocxRunStyle, out: DocxRun[]): void {
    const style = baseStyle.clone();
    const rPr = node.child('w:rPr');
    if (rPr !== null) {
      const styleId = rPr.childVal('w:rStyle');
      if (styleId.length > 0) {
        this.applyStyleChain(styleId, null, style, 0);
      }
      this.applyRunProps(rPr, style);
    }
    for (let i = 0; i < node.children.length; i++) {
      const child = node.children[i];
      const name = child.localName;
      if (name === 't') {
        const run = new DocxRun();
        run.style = style;
        run.text = child.text;
        out.push(run);
        continue;
      }
      if (name === 'tab') {
        const run = new DocxRun();
        run.style = style;
        run.text = '\t';
        out.push(run);
        continue;
      }
      if (name === 'br') {
        const run = new DocxRun();
        run.style = style;
        run.breakKind = child.attr('w:type') === 'page' ? DocxRun.BREAK_PAGE : DocxRun.BREAK_LINE;
        out.push(run);
        continue;
      }
      if (name === 'cr') {
        const run = new DocxRun();
        run.style = style;
        run.breakKind = DocxRun.BREAK_LINE;
        out.push(run);
        continue;
      }
      if (name === 'drawing' || name === 'pict' || name === 'object') {
        const image = this.parseImage(child);
        if (image !== null) {
          const run = new DocxRun();
          run.style = style;
          run.image = image;
          out.push(run);
        }
        continue;
      }
      if (name === 'sym') {
        // 符号字符：`w:char` 是十六进制码位（多在私用区，统一按项目符号处理）
        const run = new DocxRun();
        run.style = style;
        run.text = '•';
        out.push(run);
        continue;
      }
      if (name === 'AlternateContent') {
        this.collectAlternate(child, style, out, 1);
        continue;
      }
      // Word 2010+ 常把图片包在 mc:Choice 之外的容器里，继续往里挖
      if (child.children.length > 0 && name !== 'rPr') {
        this.collectRuns(child, style, out, 1);
      }
    }
  }

  /**
   * 解析图片：从 w:drawing / w:pict 里找关系 ID 与显示尺寸。
   *
   * 关键坑：wp:docPr 有一个数字 `id`（绘图编号），和关系 `r:id` 不是一回事。
   * 必须先找 `r:embed`，绝不能把裸 `id` 当成关系。
   */
  private parseImage(node: XmlNode): DocxImage | null {
    const embedId = DocxParser.findEmbedId(node);
    if (embedId.length === 0) {
      return null;
    }
    const target = this.rels.get(embedId);
    if (target === undefined) {
      return null;
    }
    let data = this.mediaCache.get(target);
    if (data === undefined) {
      data = this.readMedia(target);
      if (data === null) {
        return null;
      }
      this.mediaCache.set(target, data);
    }
    const image = new DocxImage();
    image.data = data;
    image.ext = DocxParser.extensionOf(target);
    this.applyImageSize(node, image);
    if (image.widthPt <= 0 || image.heightPt <= 0) {
      // 没有版式尺寸就按像素、96dpi 估算，总比把图丢掉好
      const px = DocxParser.imagePixelSize(data);
      if (px !== null) {
        image.widthPt = px[0] * 72 / 96;
        image.heightPt = px[1] * 72 / 96;
      }
    }
    if (image.widthPt <= 0 || image.heightPt <= 0) {
      image.widthPt = 160;
      image.heightPt = 120;
    }
    return image;
  }

  /** 从 ZIP 读媒体文件；路径斜杠/大小写对不上时由 ZipArchive 兜底 */
  private readMedia(target: string): Uint8Array | null {
    if (target.length === 0) {
      return null;
    }
    if (!this.archive.has(target)) {
      return null;
    }
    try {
      return this.archive.read(target);
    } catch (e) {
      return null;
    }
  }

  /** 显示尺寸：wp:extent（EMU）→ a:ext → VML style */
  private applyImageSize(node: XmlNode, image: DocxImage): void {
    const extent = DocxParser.findNode(node, 'extent', 0);
    if (extent !== null) {
      image.widthPt = DocxUnits.emuToPt(DocxParser.parseNum(extent.attr('cx'), 0));
      image.heightPt = DocxUnits.emuToPt(DocxParser.parseNum(extent.attr('cy'), 0));
    }
    if (image.widthPt <= 0 || image.heightPt <= 0) {
      const ext = DocxParser.findSizedExt(node, 0);
      if (ext !== null) {
        image.widthPt = DocxUnits.emuToPt(DocxParser.parseNum(ext.attr('cx'), 0));
        image.heightPt = DocxUnits.emuToPt(DocxParser.parseNum(ext.attr('cy'), 0));
      }
    }
    if (image.widthPt <= 0 || image.heightPt <= 0) {
      const shape = DocxParser.findNode(node, 'shape', 0);
      if (shape !== null) {
        const style = shape.attr('style');
        image.widthPt = DocxParser.cssLength(style, 'width');
        image.heightPt = DocxParser.cssLength(style, 'height');
      }
    }
  }

  /** 找带 cx/cy 的 a:ext（图片变换框），不要误匹配 extLst */
  private static findSizedExt(node: XmlNode, depth: number): XmlNode | null {
    if (depth > 24) {
      return null;
    }
    if (node.localName === 'ext' && (node.attr('cx').length > 0 || node.attr('cy').length > 0)) {
      return node;
    }
    for (let i = 0; i < node.children.length; i++) {
      const found = DocxParser.findSizedExt(node.children[i], depth + 1);
      if (found !== null) {
        return found;
      }
    }
    return null;
  }

  /**
   * 找图片关系 ID。
   * 第一遍只认 embed（DrawingML 的 a:blip r:embed）；
   * 找不到再认 VML 的 r:id / o:relid。绝不把裸 id 当成关系。
   */
  private static findEmbedId(node: XmlNode): string {
    const embed = DocxParser.findAttrDeep(node, 'embed', 0);
    if (embed.length > 0) {
      return embed;
    }
    return DocxParser.findRelationshipIdDeep(node, 0);
  }

  /** 整棵子树里按本地名找属性（r:embed / ns0:embed / embed） */
  private static findAttrDeep(node: XmlNode, localName: string, depth: number): string {
    if (depth > 24) {
      return '';
    }
    const v = node.attrLocal(localName);
    if (v.length > 0) {
      return v;
    }
    for (let i = 0; i < node.children.length; i++) {
      const found = DocxParser.findAttrDeep(node.children[i], localName, depth + 1);
      if (found.length > 0) {
        return found;
      }
    }
    return '';
  }

  /** VML / 链接图：带前缀的 r:id，跳过超链接 */
  private static findRelationshipIdDeep(node: XmlNode, depth: number): string {
    if (depth > 24) {
      return '';
    }
    if (node.localName !== 'hlinkClick' && node.localName !== 'hlinkHover') {
      const rid = node.attrExact('r:id');
      if (rid.length > 0) {
        return rid;
      }
      // 其它前缀的 :id（ns1:id），但不要裸 id
      let prefixedId = '';
      node.attrs.forEach((value: string, key: string) => {
        if (prefixedId.length === 0 && key.endsWith(':id') && key !== 'xml:id') {
          prefixedId = value;
        }
      });
      if (prefixedId.length > 0) {
        return prefixedId;
      }
      const relid = node.attrLocal('relid');
      if (relid.length > 0) {
        return relid;
      }
      if (node.localName === 'blip') {
        const link = node.attrLocal('link');
        if (link.length > 0) {
          return link;
        }
      }
    }
    for (let i = 0; i < node.children.length; i++) {
      const found = DocxParser.findRelationshipIdDeep(node.children[i], depth + 1);
      if (found.length > 0) {
        return found;
      }
    }
    return '';
  }

  /** JPEG / PNG / BMP 文件头里的像素尺寸 */
  private static imagePixelSize(data: Uint8Array): number[] | null {
    if (data.length >= 2 && data[0] === 0xff && data[1] === 0xd8) {
      return DocxParser.jpegSize(data);
    }
    const png = PngDecoder.size(data);
    if (png !== null) {
      return png;
    }
    return BmpDecoder.size(data);
  }

  /** 从 JPEG 文件头读像素尺寸 */
  private static jpegSize(data: Uint8Array): number[] | null {
    let i = 2;
    while (i + 8 < data.length) {
      if (data[i] !== 0xff) {
        i++;
        continue;
      }
      const marker = data[i + 1];
      if (marker === 0xd8 || marker === 0xd9 || marker === 0x01) {
        i += 2;
        continue;
      }
      const len = (data[i + 2] << 8) | data[i + 3];
      if ((marker >= 0xc0 && marker <= 0xc3) || (marker >= 0xc9 && marker <= 0xcb)) {
        if (i + 8 < data.length) {
          const h = (data[i + 5] << 8) | data[i + 6];
          const w = (data[i + 7] << 8) | data[i + 8];
          return [w, h];
        }
      }
      i += 2 + len;
    }
    return null;
  }

  /** 递归按本地名找第一个节点 */
  private static findNode(node: XmlNode, localName: string, depth: number): XmlNode | null {
    if (depth > 24) {
      return null;
    }
    if (node.localName === localName) {
      return node;
    }
    for (let i = 0; i < node.children.length; i++) {
      const found = DocxParser.findNode(node.children[i], localName, depth + 1);
      if (found !== null) {
        return found;
      }
    }
    return null;
  }

  /** 从 CSS 样式串里取长度（只认 pt 与 px） */
  private static cssLength(style: string, name: string): number {
    const key = name + ':';
    const at = style.indexOf(key);
    if (at < 0) {
      return 0;
    }
    let value = '';
    for (let i = at + key.length; i < style.length; i++) {
      const c = style.charAt(i);
      if (c === ';') {
        break;
      }
      value += c;
    }
    const num = DocxParser.parseNum(value, 0);
    if (value.indexOf('px') >= 0) {
      return num * 0.75; // 96dpi 下 1px = 0.75pt
    }
    return num;
  }

  /** 取文件扩展名（小写） */
  private static extensionOf(path: string): string {
    const dot = path.lastIndexOf('.');
    if (dot < 0) {
      return '';
    }
    return path.substring(dot + 1).toLowerCase();
  }

  /** 解析表格 */
  private parseTable(node: XmlNode): DocxTable {
    const table = new DocxTable();
    const grid = node.child('w:tblGrid');
    if (grid !== null) {
      const cols = grid.childrenNamed('w:gridCol');
      for (let i = 0; i < cols.length; i++) {
        table.columnsPt.push(DocxUnits.twipToPt(DocxParser.parseNum(cols[i].attr('w:w'), 0)));
      }
    }
    // 表格默认边框
    const defaultBorders = new DocxBorders();
    const tblPr = node.child('w:tblPr');
    if (tblPr !== null) {
      const borders = tblPr.child('w:tblBorders');
      if (borders !== null) {
        DocxParser.applyBorders(borders, defaultBorders);
      }
      const margins = tblPr.child('w:tblCellMar');
      if (margins !== null) {
        const left = margins.child('w:left');
        if (left !== null) {
          table.cellPadPt = DocxUnits.twipToPt(DocxParser.parseNum(left.attr('w:w'), 108));
        }
      }
      // tblStyle 里也可能定义边框，样式表里取不到就给个细边（Word 默认表格样式带边框）
      const styleId = tblPr.childVal('w:tblStyle');
      if (styleId.length > 0 && defaultBorders.topPt === 0 && borders === null) {
        defaultBorders.topPt = 0.5;
        defaultBorders.bottomPt = 0.5;
        defaultBorders.leftPt = 0.5;
        defaultBorders.rightPt = 0.5;
      }
    }

    const rowNodes = node.childrenNamed('w:tr');
    for (let r = 0; r < rowNodes.length; r++) {
      const rowNode = rowNodes[r];
      const row = new DocxRow();
      const trPr = rowNode.child('w:trPr');
      if (trPr !== null) {
        const height = trPr.child('w:trHeight');
        if (height !== null) {
          row.heightPt = DocxUnits.twipToPt(DocxParser.parseNum(height.attr('w:val'), 0));
        }
        row.header = trPr.child('w:tblHeader') !== null;
      }
      const cellNodes = rowNode.childrenNamed('w:tc');
      for (let c = 0; c < cellNodes.length; c++) {
        row.cells.push(this.parseCell(cellNodes[c], defaultBorders));
      }
      table.rows.push(row);
    }
    if (table.columnsPt.length === 0 && table.rows.length > 0) {
      // 没有 tblGrid：按第一行的单元格数平分
      const count = Math.max(1, table.rows[0].cells.length);
      for (let i = 0; i < count; i++) {
        table.columnsPt.push(0); // 0 表示由排版阶段平分
      }
    }
    return table;
  }

  /** 解析单元格 */
  private parseCell(node: XmlNode, defaultBorders: DocxBorders): DocxCell {
    const cell = new DocxCell();
    cell.borders = defaultBorders.clone();
    const tcPr = node.child('w:tcPr');
    if (tcPr !== null) {
      const span = tcPr.child('w:gridSpan');
      if (span !== null) {
        cell.gridSpan = Math.max(1, Math.trunc(DocxParser.parseNum(span.attr('w:val'), 1)));
      }
      const vMerge = tcPr.child('w:vMerge');
      if (vMerge !== null) {
        const val = vMerge.attr('w:val');
        cell.vMergeContinue = val.length === 0 || val === 'continue';
      }
      const borders = tcPr.child('w:tcBorders');
      if (borders !== null) {
        DocxParser.applyBorders(borders, cell.borders);
      }
      const shd = tcPr.child('w:shd');
      if (shd !== null) {
        const fill = DocxParser.parseColor(shd.attr('w:fill'));
        if (fill >= 0) {
          cell.fill = fill;
        }
      }
    }
    for (let i = 0; i < node.children.length; i++) {
      const child = node.children[i];
      if (child.localName === 'p') {
        cell.blocks.push(this.parseParagraph(child));
      } else if (child.localName === 'tbl') {
        cell.blocks.push(this.parseTable(child));
      }
    }
    return cell;
  }

  /** 解析边框定义 */
  private static applyBorders(node: XmlNode, borders: DocxBorders): void {
    const top = node.child('w:top');
    const bottom = node.child('w:bottom');
    const left = node.child('w:left');
    const right = node.child('w:right');
    const insideH = node.child('w:insideH');
    const insideV = node.child('w:insideV');
    if (top !== null) {
      borders.topPt = DocxParser.borderWidth(top);
    }
    if (bottom !== null) {
      borders.bottomPt = DocxParser.borderWidth(bottom);
    }
    if (left !== null) {
      borders.leftPt = DocxParser.borderWidth(left);
    }
    if (right !== null) {
      borders.rightPt = DocxParser.borderWidth(right);
    }
    // 内部框线：表格级定义时用来给所有单元格补上四边
    if (insideH !== null) {
      const w = DocxParser.borderWidth(insideH);
      if (borders.topPt === 0) {
        borders.topPt = w;
      }
      if (borders.bottomPt === 0) {
        borders.bottomPt = w;
      }
    }
    if (insideV !== null) {
      const w = DocxParser.borderWidth(insideV);
      if (borders.leftPt === 0) {
        borders.leftPt = w;
      }
      if (borders.rightPt === 0) {
        borders.rightPt = w;
      }
    }
    const anyColor = top !== null ? top : (left !== null ? left : (bottom !== null ? bottom : right));
    if (anyColor !== null) {
      const color = DocxParser.parseColor(anyColor.attr('w:color'));
      if (color >= 0) {
        borders.color = color;
      }
    }
  }

  /** 边框线宽：w:sz 单位是 1/8 磅，`none`/`nil` 表示无边框 */
  private static borderWidth(node: XmlNode): number {
    const val = node.attr('w:val');
    if (val === 'none' || val === 'nil') {
      return 0;
    }
    const sz = DocxParser.parseNum(node.attr('w:sz'), 4);
    const pt = DocxUnits.eighthToPt(sz);
    return pt > 0 ? Math.max(0.4, pt) : 0.5;
  }
}
