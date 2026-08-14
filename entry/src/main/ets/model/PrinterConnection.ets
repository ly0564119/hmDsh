/**
 * 打印机 TCP 连接（9100 端口 raw）。
 */

import { socket } from '@kit.NetworkKit';

export class PrinterConnection {
  private tcp: socket.TCPSocket | null = null;

  isConnected(): boolean {
    return this.tcp !== null;
  }

  async connect(ip: string, port: number, timeoutMs: number = 5000): Promise<void> {
    if (this.tcp) {
      await this.close();
    }
    const tcp = socket.constructTCPSocketInstance();
    await tcp.connect({
      address: {
        address: ip,
        port: port,
        family: 1
      },
      timeout: timeoutMs
    });
    this.tcp = tcp;
  }

  async send(data: ArrayBuffer): Promise<void> {
    if (!this.tcp) {
      throw new Error('打印机未连接');
    }
    await this.tcp.send({ data: data });
  }

  async close(): Promise<void> {
    if (this.tcp) {
      const t = this.tcp;
      this.tcp = null;
      await t.close();
    }
  }
}
