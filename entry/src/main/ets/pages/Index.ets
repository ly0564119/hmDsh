import { promptAction } from '@kit.ArkUI';
import { picker, fileIo as fs } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { PrintService } from '../model/PrintService';
import { EscPrDpi, EscPrPaper } from '../model/EscPrEncoder';
import { PrinterDiscovery, DiscoveredPrinter } from '../model/PrinterDiscovery';

const TAG: string = 'L805Index';

@Entry
@Component
struct Index {
  @State ip: string = '';
  @State status: string = '就绪';
  @State busy: boolean = false;
  @State discovering: boolean = false;
  @State foundList: DiscoveredPrinter[] = [];
  @State paperIndex: number = 0;    // 0 A4 / 1 Letter / 2 明信片
  @State qualityIndex: number = 0;  // 0 标准 300 / 1 高 600
  private service: PrintService = new PrintService();
  private discovery: PrinterDiscovery = new PrinterDiscovery();
  private paperOptions: SelectOption[] = [
    { value: 'A4' },
    { value: 'Letter' },
    { value: '4x6 / 明信片' }
  ];
  private qualityOptions: SelectOption[] = [
    { value: '标准 (300dpi)' },
    { value: '高质量 (600dpi)' }
  ];

  aboutToAppear(): void {
    PersistentStorage.persistProp('printer_ip', '');
    const saved = AppStorage.get<string>('printer_ip');
    if (saved !== undefined && saved.length > 0) {
      this.ip = saved;
    }
  }

  private dpi(): number {
    return this.qualityIndex === 0 ? EscPrDpi.LOW : EscPrDpi.HIGH;
  }

  private paper(): number {
    if (this.paperIndex === 1) {
      return EscPrPaper.LETTER;
    }
    if (this.paperIndex === 2) {
      return EscPrPaper.POSTCARD;
    }
    return EscPrPaper.A4;
  }

  private fontSizePx(): number {
    return Math.round(11 / 72 * this.dpi());
  }

  private marginPx(): number {
    return Math.round(8 / 25.4 * this.dpi());
  }

  private validateIp(): boolean {
    const t = this.ip.trim();
    if (t.length === 0) {
      this.status = '请先输入打印机 IP 地址';
      promptAction.showToast({ message: '请先输入打印机 IP 地址' });
      return false;
    }
    this.ip = t;
    AppStorage.setOrCreate('printer_ip', t);
    return true;
  }

  private async runTask(task: () => Promise<number>): Promise<void> {
    this.busy = true;
    this.status = '正在处理…';
    try {
      const pages = await task();
      this.status = '打印完成，共 ' + pages + ' 页';
      promptAction.showToast({ message: '打印完成' });
    } catch (e) {
      hilog.error(0x0000, TAG, 'print task failed');
      this.status = '打印失败，请检查打印机 IP 与网络';
      promptAction.showToast({ message: '打印失败，请检查打印机 IP 与网络' });
    } finally {
      this.busy = false;
    }
  }

  private async discover(): Promise<void> {
    this.discovering = true;
    this.foundList = [];
    this.status = '正在扫描局域网…';
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const list = await this.discovery.scan(ctx, 4000);
      this.foundList = list;
      if (list.length === 0) {
        this.status = '未发现打印机，可手动输入 IP';
        promptAction.showToast({ message: '未发现打印机' });
      } else {
        this.status = '发现 ' + list.length + ' 台设备，点击填入 IP';
      }
    } catch (e) {
      hilog.error(0x0000, TAG, 'discovery failed');
      this.status = '扫描失败，请手动输入 IP';
    } finally {
      this.discovering = false;
    }
  }

  private async pickAndPrintText(): Promise<void> {
    if (!this.validateIp()) {
      return;
    }
    const docPicker = new picker.DocumentViewPicker();
    const opts = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 1;
    opts.fileSuffixFilters = ['.txt'];
    let uris: string[] = [];
    try {
      uris = await docPicker.select(opts);
    } catch (e) {
      this.status = '已取消选择文件';
      return;
    }
    if (uris.length === 0) {
      this.status = '未选择文件';
      return;
    }
    const uri = uris[0];
    let content = '';
    try {
      content = fs.readTextSync(uri);
    } catch (e) {
      this.status = '读取文件失败（请使用 UTF-8 编码的 .txt）';
      return;
    }
    if (content.length === 0) {
      this.status = '文件内容为空';
      return;
    }
    await this.runTask(() =>
      this.service.printText(this.ip, content, this.dpi(), this.paper(), this.fontSizePx(), this.marginPx())
    );
  }

  private async pickAndPrintPhoto(): Promise<void> {
    if (!this.validateIp()) {
      return;
    }
    const photoPicker = new photoAccessHelper.PhotoViewPicker();
    const opts = new photoAccessHelper.PhotoSelectOptions();
    opts.MIMEType = photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE;
    opts.maxSelectNumber = 1;
    let result: photoAccessHelper.PhotoSelectResult | null = null;
    try {
      result = await photoPicker.select(opts);
    } catch (e) {
      this.status = '已取消选择图片';
      return;
    }
    if (result === null || result.photoUris.length === 0) {
      this.status = '未选择图片';
      return;
    }
    const uri = result.photoUris[0];
    await this.runTask(() =>
      this.service.printPhoto(this.ip, uri, this.dpi(), this.paper())
    );
  }

  /** 打印 Office：kind ∈ {docx, xlsx} */
  private async pickAndPrintOffice(kind: string): Promise<void> {
    if (!this.validateIp()) {
      return;
    }
    const suffix = kind === 'docx' ? '.docx' : '.xlsx';
    const docPicker = new picker.DocumentViewPicker();
    const opts = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 1;
    opts.fileSuffixFilters = [suffix];
    let uris: string[] = [];
    try {
      uris = await docPicker.select(opts);
    } catch (e) {
      this.status = '已取消选择文件';
      return;
    }
    if (uris.length === 0) {
      this.status = '未选择文件';
      return;
    }
    const uri = uris[0];
    const ctx = getContext(this) as common.UIAbilityContext;
    if (kind === 'docx') {
      await this.runTask(() =>
        this.service.printDocx(this.ip, uri, this.dpi(), this.paper(), this.fontSizePx(), this.marginPx(), ctx.cacheDir)
      );
    } else {
      await this.runTask(() =>
        this.service.printXlsx(this.ip, uri, this.dpi(), this.paper(), this.fontSizePx(), this.marginPx(), ctx.cacheDir)
      );
    }
  }

  build() {
    Scroll() {
      Column({ space: 14 }) {
        Text('爱普生 L805 打印')
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .margin({ top: 24 })

        Column({ space: 8 }) {
          Text('打印机 IP 地址')
            .fontSize(13)
            .foregroundColor('#666666')
            .width('100%')
          Row({ space: 8 }) {
            TextInput({ text: this.ip, placeholder: '例如 192.168.1.100' })
              .layoutWeight(1)
              .onChange((value: string) => {
                this.ip = value;
              })
            Button('发现')
              .enabled(!this.discovering && !this.busy)
              .onClick(() => {
                this.discover();
              })
          }
          .width('100%')

          if (this.foundList.length > 0) {
            ForEach(this.foundList, (item: DiscoveredPrinter) => {
              Button(item.name + '  (' + item.ip + ')')
                .width('100%')
                .fontSize(13)
                .onClick(() => {
                  this.ip = item.ip;
                  AppStorage.setOrCreate('printer_ip', item.ip);
                  this.status = '已选择 ' + item.ip;
                })
            }, (item: DiscoveredPrinter) => item.ip)
          }
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 8 }) {
          Text('纸张')
            .fontSize(13)
            .foregroundColor('#666666')
            .width('100%')
          Select(this.paperOptions)
            .selected(this.paperIndex)
            .value(this.paperOptions[this.paperIndex].value)
            .width('100%')
            .onSelect((index: number, value: string) => {
              this.paperIndex = index;
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 8 }) {
          Text('打印质量')
            .fontSize(13)
            .foregroundColor('#666666')
            .width('100%')
          Select(this.qualityOptions)
            .selected(this.qualityIndex)
            .value(this.qualityOptions[this.qualityIndex].value)
            .width('100%')
            .onSelect((index: number, value: string) => {
              this.qualityIndex = index;
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Button('打印文本（.txt）')
          .width('100%')
          .enabled(!this.busy)
          .onClick(() => {
            this.pickAndPrintText();
          })

        Button('打印照片')
          .width('100%')
          .enabled(!this.busy)
          .onClick(() => {
            this.pickAndPrintPhoto();
          })

        Button('打印 Word（.docx）')
          .width('100%')
          .enabled(!this.busy)
          .onClick(() => {
            this.pickAndPrintOffice('docx');
          })

        Button('打印 Excel（.xlsx）')
          .width('100%')
          .enabled(!this.busy)
          .onClick(() => {
            this.pickAndPrintOffice('xlsx');
          })

        Text(this.status)
          .fontSize(14)
          .foregroundColor('#333333')
          .width('100%')
          .textAlign(TextAlign.Center)
          .margin({ top: 8 })
      }
      .width('100%')
      .padding({ left: 24, right: 24, bottom: 24 })
    }
    .width('100%')
    .height('100%')
    .scrollable(ScrollDirection.Vertical)
    .scrollBar(BarState.Auto)
  }
}
