/**
 * 动态字节缓冲，用于拼装 ESC/P-R 打印任务。
 */

export class ByteWriter {
  private buf: Uint8Array;
  private len: number = 0;

  constructor(initialCapacity: number = 64 * 1024) {
    this.buf = new Uint8Array(initialCapacity);
  }

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

  /** 小端写入 16 位整数 */
  writeU16LE(v: number): void {
    this.ensure(2);
    this.buf[this.len] = v & 0xff;
    this.buf[this.len + 1] = (v >> 8) & 0xff;
    this.len += 2;
  }

  /** 小端写入 32 位整数 */
  writeU32LE(v: number): void {
    this.ensure(4);
    this.buf[this.len] = v & 0xff;
    this.buf[this.len + 1] = (v >> 8) & 0xff;
    this.buf[this.len + 2] = (v >> 16) & 0xff;
    this.buf[this.len + 3] = (v >> 24) & 0xff;
    this.len += 4;
  }

  /** 取最终字节数组（拷贝） */
  toBytes(): Uint8Array {
    const out = new Uint8Array(this.len);
    out.set(this.buf.subarray(0, this.len));
    return out;
  }

  /** 把内容复制到新的 ArrayBuffer（用于 socket send） */
  toArrayBuffer(): ArrayBuffer {
    const out = new ArrayBuffer(this.len);
    new Uint8Array(out).set(this.buf.subarray(0, this.len));
    return out;
  }
}
