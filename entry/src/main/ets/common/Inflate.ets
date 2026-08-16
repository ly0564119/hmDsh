/**
 * DEFLATE（RFC 1951）解压，纯 ArkTS 实现，用于在内存里解开 .docx / .xlsx 的 ZIP 条目。
 *
 * 为什么不用 @ohos.zlib：它只有 decompressFile(zip 文件 → 目录) 这种「落盘」接口，
 * 需要先把 picker 返回的 URI 拷成沙箱文件、再解压到目录、再按路径读文件，
 * 中间任一环节（URI 不能直接当路径、后缀限制、目录权限）失败都会让 Word 打印整体失败。
 * 直接在内存里解压更可控，也省掉临时文件清理。
 */

/** 规范霍夫曼编码表（按码长计数 + 按码长排序的符号表） */
class HuffmanTable {
  /** counts[len] = 码长为 len 的符号个数 */
  readonly counts: Uint16Array = new Uint16Array(16);
  /** 按码长升序排列的符号 */
  readonly symbols: Uint16Array;

  constructor(symbolCount: number) {
    this.symbols = new Uint16Array(symbolCount);
  }
}

export class Inflate {
  /** 长度码 257~285 对应的基础长度 */
  private static readonly LENGTH_BASE: number[] = [
    3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31,
    35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258
  ];
  /** 长度码额外位数 */
  private static readonly LENGTH_EXTRA: number[] = [
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2,
    3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0
  ];
  /** 距离码 0~29 对应的基础距离 */
  private static readonly DIST_BASE: number[] = [
    1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193,
    257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577
  ];
  /** 距离码额外位数 */
  private static readonly DIST_EXTRA: number[] = [
    0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6,
    7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13
  ];
  /** 码长表本身的传输顺序（RFC 1951 3.2.7） */
  private static readonly CODE_LENGTH_ORDER: number[] = [
    16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15
  ];

  private readonly src: Uint8Array;
  private srcPos: number;
  private readonly srcEnd: number;
  /** 位缓存（DEFLATE 是低位优先） */
  private bitBuf: number = 0;
  private bitCount: number = 0;

  private out: Uint8Array;
  private outLen: number = 0;

  private constructor(src: Uint8Array, offset: number, length: number, expectedSize: number) {
    this.src = src;
    this.srcPos = offset;
    this.srcEnd = offset + length;
    this.out = new Uint8Array(expectedSize > 0 ? expectedSize : Math.max(1024, length * 4));
  }

  /**
   * 解压裸 DEFLATE 数据（不含 zlib/gzip 头）。
   *
   * @param src 源缓冲
   * @param offset 压缩数据起始下标
   * @param length 压缩数据字节数
   * @param expectedSize 预期解压后大小（ZIP 目录里有记录，用于一次性分配输出缓冲）
   */
  static inflateRaw(src: Uint8Array, offset: number, length: number, expectedSize: number): Uint8Array {
    const inf = new Inflate(src, offset, length, expectedSize);
    inf.run();
    return inf.result();
  }

  private result(): Uint8Array {
    if (this.outLen === this.out.length) {
      return this.out;
    }
    return this.out.subarray(0, this.outLen);
  }

  /** 输出缓冲扩容 */
  private ensureOut(extra: number): void {
    const need = this.outLen + extra;
    if (need <= this.out.length) {
      return;
    }
    let cap = this.out.length > 0 ? this.out.length * 2 : 1024;
    while (cap < need) {
      cap *= 2;
    }
    const nb = new Uint8Array(cap);
    nb.set(this.out.subarray(0, this.outLen));
    this.out = nb;
  }

  private readBit(): number {
    if (this.bitCount === 0) {
      if (this.srcPos >= this.srcEnd) {
        throw new Error('DEFLATE 数据意外结束');
      }
      this.bitBuf = this.src[this.srcPos];
      this.srcPos++;
      this.bitCount = 8;
    }
    const bit = this.bitBuf & 1;
    this.bitBuf = this.bitBuf >>> 1;
    this.bitCount--;
    return bit;
  }

  /** 低位优先读 n 位 */
  private readBits(n: number): number {
    let value = 0;
    for (let i = 0; i < n; i++) {
      value |= this.readBit() << i;
    }
    return value;
  }

  /** 由码长数组构造霍夫曼表 */
  private static buildTable(lengths: Uint8Array, count: number): HuffmanTable {
    const table = new HuffmanTable(count);
    for (let i = 0; i < count; i++) {
      table.counts[lengths[i]]++;
    }
    table.counts[0] = 0;
    const offsets = new Uint16Array(16);
    for (let len = 1; len < 16; len++) {
      offsets[len] = offsets[len - 1] + table.counts[len - 1];
    }
    for (let i = 0; i < count; i++) {
      const len = lengths[i];
      if (len > 0) {
        table.symbols[offsets[len]] = i;
        offsets[len]++;
      }
    }
    return table;
  }

  /** 按规范霍夫曼编码解出一个符号 */
  private decodeSymbol(table: HuffmanTable): number {
    let base = 0;
    let offset = 0;
    for (let len = 1; len <= 15; len++) {
      offset = offset * 2 + this.readBit();
      const cnt = table.counts[len];
      if (offset < cnt) {
        return table.symbols[base + offset];
      }
      base += cnt;
      offset -= cnt;
    }
    throw new Error('DEFLATE 霍夫曼码非法');
  }

  /** 固定霍夫曼表（RFC 1951 3.2.6） */
  private static fixedLiteralTable(): HuffmanTable {
    const lengths = new Uint8Array(288);
    for (let i = 0; i < 144; i++) {
      lengths[i] = 8;
    }
    for (let i = 144; i < 256; i++) {
      lengths[i] = 9;
    }
    for (let i = 256; i < 280; i++) {
      lengths[i] = 7;
    }
    for (let i = 280; i < 288; i++) {
      lengths[i] = 8;
    }
    return Inflate.buildTable(lengths, 288);
  }

  private static fixedDistanceTable(): HuffmanTable {
    const lengths = new Uint8Array(30);
    for (let i = 0; i < 30; i++) {
      lengths[i] = 5;
    }
    return Inflate.buildTable(lengths, 30);
  }

  /** 读动态块的两张码表 */
  private readDynamicTables(): HuffmanTable[] {
    const hlit = this.readBits(5) + 257;
    const hdist = this.readBits(5) + 1;
    const hclen = this.readBits(4) + 4;

    const codeLengths = new Uint8Array(19);
    for (let i = 0; i < hclen; i++) {
      codeLengths[Inflate.CODE_LENGTH_ORDER[i]] = this.readBits(3);
    }
    const clTable = Inflate.buildTable(codeLengths, 19);

    const lengths = new Uint8Array(hlit + hdist);
    let i = 0;
    while (i < hlit + hdist) {
      const sym = this.decodeSymbol(clTable);
      if (sym < 16) {
        lengths[i] = sym;
        i++;
      } else if (sym === 16) {
        // 重复上一个码长 3~6 次
        if (i === 0) {
          throw new Error('DEFLATE 码长表非法');
        }
        const prev = lengths[i - 1];
        const repeat = 3 + this.readBits(2);
        for (let k = 0; k < repeat; k++) {
          lengths[i] = prev;
          i++;
        }
      } else if (sym === 17) {
        // 重复 0 共 3~10 次
        const repeat = 3 + this.readBits(3);
        i += repeat;
      } else {
        // 重复 0 共 11~138 次
        const repeat = 11 + this.readBits(7);
        i += repeat;
      }
    }
    return [
      Inflate.buildTable(lengths.subarray(0, hlit), hlit),
      Inflate.buildTable(lengths.subarray(hlit, hlit + hdist), hdist)
    ];
  }

  /** 解一个压缩块（固定表或动态表） */
  private inflateBlock(literalTable: HuffmanTable, distanceTable: HuffmanTable): void {
    while (true) {
      const sym = this.decodeSymbol(literalTable);
      if (sym === 256) {
        return;
      }
      if (sym < 256) {
        this.ensureOut(1);
        this.out[this.outLen] = sym;
        this.outLen++;
        continue;
      }
      const lenIdx = sym - 257;
      if (lenIdx >= Inflate.LENGTH_BASE.length) {
        throw new Error('DEFLATE 长度码非法: ' + sym);
      }
      const length = Inflate.LENGTH_BASE[lenIdx] + this.readBits(Inflate.LENGTH_EXTRA[lenIdx]);
      const distSym = this.decodeSymbol(distanceTable);
      if (distSym >= Inflate.DIST_BASE.length) {
        throw new Error('DEFLATE 距离码非法: ' + distSym);
      }
      const dist = Inflate.DIST_BASE[distSym] + this.readBits(Inflate.DIST_EXTRA[distSym]);
      if (dist > this.outLen) {
        throw new Error('DEFLATE 回溯距离超出已解压数据');
      }
      this.ensureOut(length);
      let from = this.outLen - dist;
      for (let k = 0; k < length; k++) {
        this.out[this.outLen] = this.out[from];
        this.outLen++;
        from++;
      }
    }
  }

  /** 存储块（未压缩），需要先按字节对齐 */
  private copyStoredBlock(): void {
    this.bitBuf = 0;
    this.bitCount = 0;
    if (this.srcPos + 4 > this.srcEnd) {
      throw new Error('DEFLATE 存储块头不完整');
    }
    const len = this.src[this.srcPos] | (this.src[this.srcPos + 1] << 8);
    const nlen = this.src[this.srcPos + 2] | (this.src[this.srcPos + 3] << 8);
    this.srcPos += 4;
    if ((len ^ 0xffff) !== nlen) {
      throw new Error('DEFLATE 存储块长度校验失败');
    }
    if (this.srcPos + len > this.srcEnd) {
      throw new Error('DEFLATE 存储块数据不完整');
    }
    this.ensureOut(len);
    this.out.set(this.src.subarray(this.srcPos, this.srcPos + len), this.outLen);
    this.outLen += len;
    this.srcPos += len;
  }

  private run(): void {
    let last = false;
    while (!last) {
      last = this.readBit() === 1;
      const type = this.readBits(2);
      if (type === 0) {
        this.copyStoredBlock();
      } else if (type === 1) {
        this.inflateBlock(Inflate.fixedLiteralTable(), Inflate.fixedDistanceTable());
      } else if (type === 2) {
        const tables = this.readDynamicTables();
        this.inflateBlock(tables[0], tables[1]);
      } else {
        throw new Error('DEFLATE 块类型非法');
      }
    }
  }
}
