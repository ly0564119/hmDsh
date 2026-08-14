/**
 * 局域网打印机发现（mDNS / 组播 DNS）。
 * 爱普生打印机通常以 _pdl-datastream._tcp（raw 9100）等类型广播。
 */

import { mdns } from '@kit.NetworkKit';
import { common } from '@kit.AbilityKit';

export class DiscoveredPrinter {
  ip: string = '';
  name: string = '';
  port: number = 9100;

  constructor(ip: string, name: string, port: number) {
    this.ip = ip;
    this.name = name;
    this.port = port;
  }
}

export class PrinterDiscovery {
  private services: mdns.DiscoveryService[] = [];

  /** 扫描局域网，返回发现的打印机列表 */
  async scan(context: common.Context, timeoutMs: number): Promise<DiscoveredPrinter[]> {
    const found: DiscoveredPrinter[] = [];
    const seen: string[] = [];
    const types: string[] = ['_pdl-datastream._tcp', '_ipp._tcp', '_printer._tcp'];

    for (let i = 0; i < types.length; i++) {
      const ds = mdns.createDiscoveryService(context, types[i]);
      ds.on('serviceFound', (data) => {
        if (data.host !== undefined && data.host !== null &&
          data.host.address !== undefined && data.host.address.length > 0) {
          if (seen.indexOf(data.host.address) < 0) {
            seen.push(data.host.address);
            const port = (data.port !== undefined && data.port > 0) ? data.port : 9100;
            found.push(new DiscoveredPrinter(data.host.address, data.serviceName, port));
          }
        }
      });
      ds.startSearchingMDNS();
      this.services.push(ds);
    }

    await new Promise<void>((resolve) => {
      setTimeout(() => {
        resolve();
      }, timeoutMs);
    });

    for (let i = 0; i < this.services.length; i++) {
      this.services[i].stopSearchingMDNS();
    }
    this.services = [];
    return found;
  }
}
