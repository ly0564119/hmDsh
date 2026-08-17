/**
 * 轻量 XML 树解析器（纯 ArkTS，无第三方依赖）。
 *
 * 之前 docx 只提取纯文字，用「扫标签」的方式就够了；现在要还原版式
 * （段落属性、字符属性、表格结构、图片关系），必须拿到真正的树结构。
 *
 * 只实现 Office Open XML 用得到的部分：
 *  - 元素、属性、文本、自闭合标签、CDATA、注释、处理指令（`<?xml ... ?>`）；
 *  - 标签名保留命名空间前缀（`w:p`），OOXML 的前缀是固定写法，按前缀匹配最省事；
 *  - 实体只处理 XML 预定义的 5 个 + 数字实体。
 * 不做 DTD、命名空间解析、实体声明——docx 里不会出现。
 */

/** 一个 XML 元素 */
export class XmlNode {
  /** 标签名（含前缀，如 `w:p`） */
  readonly name: string;
  /** 属性表（键含前缀，如 `w:val`） */
  readonly attrs: Map<string, string> = new Map<string, string>();
  /** 子元素 */
  readonly children: XmlNode[] = [];
  /** 直接文本内容（元素内的文本节点拼接） */
  text: string = '';

  constructor(name: string) {
    this.name = name;
  }

  /** 去掉命名空间前缀后的标签名 */
  get localName(): string {
    const colon = this.name.indexOf(':');
    return colon >= 0 ? this.name.substring(colon + 1) : this.name;
  }

  /** 取属性，缺失返回空串 */
  attr(name: string): string {
    const v = this.attrs.get(name);
    if (v !== undefined) {
      return v;
    }
    // 兼容不带前缀的写法
    const colon = name.indexOf(':');
    if (colon >= 0) {
      const local = name.substring(colon + 1);
      const v2 = this.attrs.get(local);
      if (v2 !== undefined) {
        return v2;
      }
    }
    return '';
  }

  /** 是否有该属性 */
  hasAttr(name: string): boolean {
    return this.attrs.has(name);
  }

  /** 第一个指定标签名的子元素，找不到返回 null */
  child(name: string): XmlNode | null {
    for (let i = 0; i < this.children.length; i++) {
      if (this.children[i].name === name || this.children[i].localName === name) {
        return this.children[i];
      }
    }
    return null;
  }

  /** 全部指定标签名的子元素 */
  childrenNamed(name: string): XmlNode[] {
    const out: XmlNode[] = [];
    for (let i = 0; i < this.children.length; i++) {
      if (this.children[i].name === name || this.children[i].localName === name) {
        out.push(this.children[i]);
      }
    }
    return out;
  }

  /** 沿路径逐层取子元素，如 path(['w:pPr', 'w:jc']) */
  path(names: string[]): XmlNode | null {
    let node: XmlNode | null = this;
    for (let i = 0; i < names.length; i++) {
      if (node === null) {
        return null;
      }
      node = node.child(names[i]);
    }
    return node;
  }

  /** 子元素的 w:val 属性（OOXML 里绝大多数属性都是这个形状） */
  childVal(name: string): string {
    const node = this.child(name);
    return node === null ? '' : node.attr('w:val');
  }

  /** 递归收集所有 `<w:t>` 之类的文本（调试用） */
  allText(): string {
    let out = this.text;
    for (let i = 0; i < this.children.length; i++) {
      out += this.children[i].allText();
    }
    return out;
  }
}

export class XmlParser {
  /** XML 实体还原（含数字实体） */
  static decodeEntities(s: string): string {
    if (s.indexOf('&') < 0) {
      return s;
    }
    let out = '';
    let i = 0;
    while (i < s.length) {
      const c = s.charAt(i);
      if (c !== '&') {
        out += c;
        i++;
        continue;
      }
      const semi = s.indexOf(';', i);
      if (semi < 0 || semi - i > 12) {
        out += c;
        i++;
        continue;
      }
      const entity = s.substring(i + 1, semi);
      if (entity === 'lt') {
        out += '<';
      } else if (entity === 'gt') {
        out += '>';
      } else if (entity === 'amp') {
        out += '&';
      } else if (entity === 'quot') {
        out += '"';
      } else if (entity === 'apos') {
        out += "'";
      } else if (entity.startsWith('#x') || entity.startsWith('#X')) {
        const code = XmlParser.parseHex(entity.substring(2));
        out += code > 0 ? String.fromCharCode(code) : '';
      } else if (entity.startsWith('#')) {
        const code = XmlParser.parseDec(entity.substring(1));
        out += code > 0 ? String.fromCharCode(code) : '';
      } else {
        out += '&' + entity + ';'; // 未知实体原样保留
      }
      i = semi + 1;
    }
    return out;
  }

  private static parseDec(text: string): number {
    let v = 0;
    for (let i = 0; i < text.length; i++) {
      const c = text.charCodeAt(i);
      if (c < 0x30 || c > 0x39) {
        return -1;
      }
      v = v * 10 + (c - 0x30);
    }
    return v;
  }

  private static parseHex(text: string): number {
    let v = 0;
    for (let i = 0; i < text.length; i++) {
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

  private static isSpace(c: string): boolean {
    return c === ' ' || c === '\t' || c === '\n' || c === '\r';
  }

  /**
   * 解析 XML 文本。
   * @returns 根元素；没有元素时返回一个空的 `#document` 节点
   */
  static parse(xml: string): XmlNode {
    const root = new XmlNode('#document');
    const stack: XmlNode[] = [root];
    let i = 0;
    while (i < xml.length) {
      const lt = xml.indexOf('<', i);
      if (lt < 0) {
        XmlParser.appendText(stack, xml.substring(i));
        break;
      }
      if (lt > i) {
        XmlParser.appendText(stack, xml.substring(i, lt));
      }
      if (xml.startsWith('<!--', lt)) {
        const end = xml.indexOf('-->', lt);
        i = end < 0 ? xml.length : end + 3;
        continue;
      }
      if (xml.startsWith('<![CDATA[', lt)) {
        const end = xml.indexOf(']]>', lt);
        const content = end < 0 ? xml.substring(lt + 9) : xml.substring(lt + 9, end);
        const top = stack[stack.length - 1];
        top.text += content;
        i = end < 0 ? xml.length : end + 3;
        continue;
      }
      if (xml.startsWith('<?', lt) || xml.startsWith('<!', lt)) {
        const end = xml.indexOf('>', lt);
        i = end < 0 ? xml.length : end + 1;
        continue;
      }
      if (xml.startsWith('</', lt)) {
        const end = xml.indexOf('>', lt);
        const name = xml.substring(lt + 2, end < 0 ? xml.length : end).trim();
        // 弹到匹配的标签（容忍不配对的结束标签）
        for (let s = stack.length - 1; s >= 1; s--) {
          if (stack[s].name === name) {
            stack.length = s;
            break;
          }
        }
        i = end < 0 ? xml.length : end + 1;
        continue;
      }
      // 开始标签
      const end = XmlParser.findTagEnd(xml, lt);
      if (end < 0) {
        break;
      }
      const inner = xml.substring(lt + 1, end);
      const selfClose = inner.endsWith('/');
      const body = selfClose ? inner.substring(0, inner.length - 1) : inner;
      const node = XmlParser.parseTag(body);
      stack[stack.length - 1].children.push(node);
      if (!selfClose) {
        stack.push(node);
      }
      i = end + 1;
    }
    // 取第一个元素作为根
    if (root.children.length > 0) {
      return root.children[0];
    }
    return root;
  }

  /** 找标签的 `>`，跳过属性值里的引号 */
  private static findTagEnd(xml: string, start: number): number {
    let quote = '';
    for (let i = start + 1; i < xml.length; i++) {
      const c = xml.charAt(i);
      if (quote.length > 0) {
        if (c === quote) {
          quote = '';
        }
        continue;
      }
      if (c === '"' || c === "'") {
        quote = c;
        continue;
      }
      if (c === '>') {
        return i;
      }
    }
    return -1;
  }

  /** 解析标签体：名字 + 属性 */
  private static parseTag(body: string): XmlNode {
    let i = 0;
    while (i < body.length && !XmlParser.isSpace(body.charAt(i))) {
      i++;
    }
    const node = new XmlNode(body.substring(0, i));
    while (i < body.length) {
      while (i < body.length && XmlParser.isSpace(body.charAt(i))) {
        i++;
      }
      if (i >= body.length) {
        break;
      }
      const eq = body.indexOf('=', i);
      if (eq < 0) {
        break;
      }
      const name = body.substring(i, eq).trim();
      let j = eq + 1;
      while (j < body.length && XmlParser.isSpace(body.charAt(j))) {
        j++;
      }
      if (j >= body.length) {
        break;
      }
      const quote = body.charAt(j);
      if (quote !== '"' && quote !== "'") {
        // 没引号的属性值（不规范但见过）
        let k = j;
        while (k < body.length && !XmlParser.isSpace(body.charAt(k))) {
          k++;
        }
        node.attrs.set(name, XmlParser.decodeEntities(body.substring(j, k)));
        i = k;
        continue;
      }
      const close = body.indexOf(quote, j + 1);
      if (close < 0) {
        break;
      }
      node.attrs.set(name, XmlParser.decodeEntities(body.substring(j + 1, close)));
      i = close + 1;
    }
    return node;
  }

  /** 把文本挂到栈顶元素上 */
  private static appendText(stack: XmlNode[], raw: string): void {
    if (stack.length <= 1) {
      return; // 根之外的文本忽略
    }
    const top = stack[stack.length - 1];
    top.text += XmlParser.decodeEntities(raw);
  }
}
