/**
 * 内存 ZIP 读取（用于 .docx / .xlsx，它们本质就是 ZIP 包）。
 *
 * 只实现读取所需的最小集合：
 *  - 扫描 EOCD（End Of Central Directory）定位中央目录；
 *  - 解析中央目录条目（名字、压缩方式、大小、本地头偏移）；
 *  - 按需取单个条目，支持 store(0) 与 deflate(8) 两种压缩方式。
 *
 * 不支持加密与 ZIP64（Office 正常导出的文档都用不到），遇到会给出明确报错。
 */

import { Inflate } from './Inflate';
import { Utf8 } from './Utf8';

/** ZIP 条目元信息 */
export class ZipEntry {
  /** 条目路径，如 word/document.xml */
  name: string = '';
  /** 压缩方式：0=store，8=deflate */
  method: number = 0;
  compressedSize: number = 0;
  uncompressedSize: number = 0;
  /** 本地文件头在整个 ZIP 中的偏移 */
  localHeaderOffset: number = 0;
}

export class ZipArchive {
  private static readonly SIG_EOCD: number = 0x06054b50;
  private static readonly SIG_CENTRAL: number = 0x02014b50;
  private static readonly SIG_LOCAL: number = 0x04034b50;
  private static readonly METHOD_STORE: number = 0;
  private static readonly METHOD_DEFLATE: number = 8;

  private readonly data: Uint8Array;
  private readonly entries: ZipEntry[];

  private constructor(data: Uint8Array, entries: ZipEntry[]) {
    this.data = data;
    this.entries = entries;
  }

  /** 打开一个内存中的 ZIP 包 */
  static open(data: Uint8Array): ZipArchive {
    const eocd = ZipArchive.findEocd(data);
    if (eocd < 0) {
      throw new Error('不是有效的 ZIP/Office 文档（找不到中央目录）');
    }
    const entryCount = ZipArchive.readU16(data, eocd + 10);
    const centralSize = ZipArchive.readU32(data, eocd + 12);
    const centralOffset = ZipArchive.readU32(data, eocd + 16);
    if (centralOffset === 0xffffffff || centralSize === 0xffffffff) {
      throw new Error('暂不支持 ZIP64 格式的 Office 文档');
    }
    const entries = ZipArchive.readCentralDirectory(data, centralOffset, entryCount);
    return new ZipArchive(data, entries);
  }

  /** 从尾部向前找 EOCD 签名（注释最长 65535 字节） */
  private static findEocd(data: Uint8Array): number {
    const minPos = Math.max(0, data.length - (0xffff + 22));
    for (let i = data.length - 22; i >= minPos; i--) {
      if (ZipArchive.readU32(data, i) === ZipArchive.SIG_EOCD) {
        return i;
      }
    }
    return -1;
  }

  /** 解析中央目录里的所有条目 */
  private static readCentralDirectory(data: Uint8Array, offset: number, entryCount: number): ZipEntry[] {
    const entries: ZipEntry[] = [];
    let pos = offset;
    for (let i = 0; i < entryCount; i++) {
      if (pos + 46 > data.length || ZipArchive.readU32(data, pos) !== ZipArchive.SIG_CENTRAL) {
        break; // 目录被截断，能读多少算多少
      }
      const entry = new ZipEntry();
      const flags = ZipArchive.readU16(data, pos + 8);
      entry.method = ZipArchive.readU16(data, pos + 10);
      entry.compressedSize = ZipArchive.readU32(data, pos + 20);
      entry.uncompressedSize = ZipArchive.readU32(data, pos + 24);
      const nameLength = ZipArchive.readU16(data, pos + 28);
      const extraLength = ZipArchive.readU16(data, pos + 30);
      const commentLength = ZipArchive.readU16(data, pos + 32);
      entry.localHeaderOffset = ZipArchive.readU32(data, pos + 42);
      entry.name = Utf8.decode(data.subarray(pos + 46, pos + 46 + nameLength));
      // bit0 = 加密标记
      if ((flags & 0x0001) !== 0) {
        throw new Error('文档已加密，无法解析：' + entry.name);
      }
      entries.push(entry);
      pos += 46 + nameLength + extraLength + commentLength;
    }
    return entries;
  }

  /** 全部条目名 */
  names(): string[] {
    const list: string[] = [];
    for (let i = 0; i < this.entries.length; i++) {
      list.push(this.entries[i].name);
    }
    return list;
  }

  /** 是否存在某条目 */
  has(name: string): boolean {
    return this.find(name) !== null;
  }

  private find(name: string): ZipEntry | null {
    const want = ZipArchive.normPath(name);
    for (let i = 0; i < this.entries.length; i++) {
      if (ZipArchive.normPath(this.entries[i].name) === want) {
        return this.entries[i];
      }
    }
    // Word / WPS 有时大小写不一致（Word/media vs word/media）
    const lower = want.toLowerCase();
    for (let i = 0; i < this.entries.length; i++) {
      if (ZipArchive.normPath(this.entries[i].name).toLowerCase() === lower) {
        return this.entries[i];
      }
    }
    return null;
  }

  /** 统一斜杠，去掉开头的 ./ */
  private static normPath(path: string): string {
    let s = '';
    for (let i = 0; i < path.length; i++) {
      const c = path.charAt(i);
      s += c === '\\' ? '/' : c;
    }
    if (s.startsWith('./')) {
      return s.substring(2);
    }
    return s;
  }

  /**
   * 找第一个满足「前缀 + 后缀」的条目名，用于定位 xl/worksheets/sheetN.xml 这类路径。
   * @returns 条目名，找不到返回空串
   */
  findByPrefixSuffix(prefix: string, suffix: string): string {
    for (let i = 0; i < this.entries.length; i++) {
      const name = this.entries[i].name;
      if (name.startsWith(prefix) && name.endsWith(suffix)) {
        return name;
      }
    }
    return '';
  }

  /** 读取并解压某个条目 */
  read(name: string): Uint8Array {
    const entry = this.find(name);
    if (entry === null) {
      throw new Error('文档中缺少必要部件：' + name);
    }
    const headerOffset = entry.localHeaderOffset;
    if (headerOffset + 30 > this.data.length ||
      ZipArchive.readU32(this.data, headerOffset) !== ZipArchive.SIG_LOCAL) {
      throw new Error('ZIP 本地文件头损坏：' + name);
    }
    // 本地头里的名字/扩展域长度可能与中央目录不同，必须以本地头为准
    const nameLength = ZipArchive.readU16(this.data, headerOffset + 26);
    const extraLength = ZipArchive.readU16(this.data, headerOffset + 28);
    const dataOffset = headerOffset + 30 + nameLength + extraLength;
    if (dataOffset + entry.compressedSize > this.data.length) {
      throw new Error('ZIP 数据被截断：' + name);
    }

    if (entry.method === ZipArchive.METHOD_STORE) {
      return this.data.subarray(dataOffset, dataOffset + entry.compressedSize);
    }
    if (entry.method === ZipArchive.METHOD_DEFLATE) {
      return Inflate.inflateRaw(this.data, dataOffset, entry.compressedSize, entry.uncompressedSize);
    }
    throw new Error('不支持的 ZIP 压缩方式 ' + entry.method + '：' + name);
  }

  /** 读取某个条目并按 UTF-8 解码成文本（Office XML 都是 UTF-8） */
  readText(name: string): string {
    return Utf8.decode(this.read(name));
  }

  private static readU16(data: Uint8Array, offset: number): number {
    return data[offset] | (data[offset + 1] << 8);
  }

  private static readU32(data: Uint8Array, offset: number): number {
    return (data[offset] | (data[offset + 1] << 8) |
      (data[offset + 2] << 16)) + data[offset + 3] * 0x1000000;
  }
}
