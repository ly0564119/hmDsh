/**
 * 动态字节缓冲，用于拼装 ESC/P-R 打印任务。
 *
 * ESC/P-R 的命令头长度字段是小端，而命令参数（尺寸、偏移量等）是大端，
 * 所以两种字节序的写入方法都要提供，调用处按协议要求选用。
 */

export class ByteWriter {
  private buf: Uint8Array;
  private len: number = 0;

  constructor(initialCapacity: number = 64 * 1024) {
    this.buf = new Uint8Array(initialCapacity > 0 ? initialCapacity : 1);
  }

  /** 当前已写入的字节数 */
  get length(): number {
    return this.len;
  }

  /** 确保还能再写 extra 个字节，不够则按 2 倍扩容 */
  private ensure(extra: number): void {
    const need = this.len + extra;
    if (need <= this.buf.length) {
      return;
    }
    let cap = this.buf.length * 2;
    while (cap < need) {
      cap *= 2;
    }
    const nb = new Uint8Array(cap);
    nb.set(this.buf.subarray(0, this.len));
    this.buf = nb;
  }

  writeByte(b: number): void {
    this.ensure(1);
    this.buf[this.len] = b & 0xff;
    this.len++;
  }

  writeBytes(bytes: Uint8Array): void {
    this.ensure(bytes.length);
    this.buf.set(bytes, this.len);
    this.len += bytes.length;
  }

  /** 写入 bytes 中 [offset, offset + count) 区间 */
  writeSlice(bytes: Uint8Array, offset: number, count: number): void {
    this.ensure(count);
    this.buf.set(bytes.subarray(offset, offset + count), this.len);
    this.len += count;
  }

  /** 重复写入同一个字节 count 次 */
  writeRepeat(b: number, count: number): void {
    this.ensure(count);
    const v = b & 0xff;
    for (let i = 0; i < count; i++) {
      this.buf[this.len + i] = v;
    }
    this.len += count;
  }

  /** 按 ASCII 逐字符写入（ESC/P-R 命令名、EJL 文本都是 ASCII） */
  writeAscii(s: string): void {
    this.ensure(s.length);
    for (let i = 0; i < s.length; i++) {
      this.buf[this.len + i] = s.charCodeAt(i) & 0xff;
    }
    this.len += s.length;
  }

  /** 小端写入 16 位整数 */
  writeU16LE(v: number): void {
    this.ensure(2);
    this.buf[this.len] = v & 0xff;
    this.buf[this.len + 1] = (v >>> 8) & 0xff;
    this.len += 2;
  }

  /** 小端写入 32 位整数（ESC/P-R 命令头的参数长度用） */
  writeU32LE(v: number): void {
    this.ensure(4);
    this.buf[this.len] = v & 0xff;
    this.buf[this.len + 1] = (v >>> 8) & 0xff;
    this.buf[this.len + 2] = (v >>> 16) & 0xff;
    this.buf[this.len + 3] = (v >>> 24) & 0xff;
    this.len += 4;
  }

  /** 大端写入 16 位整数（ESC/P-R 命令参数用） */
  writeU16BE(v: number): void {
    this.ensure(2);
    this.buf[this.len] = (v >>> 8) & 0xff;
    this.buf[this.len + 1] = v & 0xff;
    this.len += 2;
  }

  /** 大端写入 32 位整数（ESC/P-R 命令参数用） */
  writeU32BE(v: number): void {
    this.ensure(4);
    this.buf[this.len] = (v >>> 24) & 0xff;
    this.buf[this.len + 1] = (v >>> 16) & 0xff;
    this.buf[this.len + 2] = (v >>> 8) & 0xff;
    this.buf[this.len + 3] = v & 0xff;
    this.len += 4;
  }

  /** 取最终字节数组（拷贝） */
  toBytes(): Uint8Array {
    const out = new Uint8Array(this.len);
    out.set(this.buf.subarray(0, this.len));
    return out;
  }

  /** 取出已写内容（拷贝）并清空缓冲，用于分块流式发送 */
  takeBytes(): Uint8Array {
    const out = this.toBytes();
    this.len = 0;
    return out;
  }

  /** 清空缓冲（容量保留，便于复用） */
  reset(): void {
    this.len = 0;
  }
}
