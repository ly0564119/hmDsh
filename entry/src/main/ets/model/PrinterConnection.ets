/**
 * 打印机 TCP 连接（9100 端口 RAW 打印）。
 *
 * 打印数据是分块流式写入的，所以这里只负责「把一段字节可靠地写出去」，
 * 不缓存整个作业。connect 失败会带上原始错误信息，便于界面提示。
 */

import { socket } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';

export class PrinterConnection {
  private tcp: socket.TCPSocket | null = null;
  /** 已写出的字节数，用于日志/诊断 */
  private sentBytes: number = 0;

  isConnected(): boolean {
    return this.tcp !== null;
  }

  get bytesSent(): number {
    return this.sentBytes;
  }

  /** 建立连接 */
  async connect(ip: string, port: number, timeoutMs: number = 8000): Promise<void> {
    if (this.tcp !== null) {
      await this.close();
    }
    const tcp = socket.constructTCPSocketInstance();
    try {
      await tcp.connect({
        address: { address: ip, port: port, family: 1 },
        timeout: timeoutMs
      });
    } catch (e) {
      const err = e as BusinessError;
      throw new Error('连接打印机 ' + ip + ':' + port + ' 失败（' + err.message + '）');
    }
    try {
      // 打印数据量大，保持长连接并放宽超时
      await tcp.setExtraOptions({ keepAlive: true, socketTimeout: 60000 });
    } catch (e) {
      // 设置不成功不影响打印，忽略
    }
    this.tcp = tcp;
    this.sentBytes = 0;
  }

  /** 写出一段字节 */
  async send(bytes: Uint8Array): Promise<void> {
    const tcp = this.tcp;
    if (tcp === null) {
      throw new Error('打印机未连接');
    }
    if (bytes.length === 0) {
      return;
    }
    // TCPSocket 只接受 ArrayBuffer；若是视图则拷成独立缓冲，避免多发数据
    let payload: ArrayBuffer;
    if (bytes.byteOffset === 0 && bytes.length === bytes.buffer.byteLength) {
      payload = bytes.buffer as ArrayBuffer;
    } else {
      const copy = new Uint8Array(bytes.length);
      copy.set(bytes);
      payload = copy.buffer as ArrayBuffer;
    }
    try {
      await tcp.send({ data: payload });
    } catch (e) {
      const err = e as BusinessError;
      throw new Error('发送打印数据失败（已发送 ' + this.sentBytes + ' 字节）：' + err.message);
    }
    this.sentBytes += bytes.length;
  }

  async close(): Promise<void> {
    const tcp = this.tcp;
    if (tcp === null) {
      return;
    }
    this.tcp = null;
    try {
      await tcp.close();
    } catch (e) {
      // 关闭失败无需向上抛，作业数据已经发完
    }
  }
}
