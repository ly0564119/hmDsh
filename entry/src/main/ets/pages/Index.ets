import { promptAction } from '@kit.ArkUI';
import { picker } from '@kit.CoreFileKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { PrintRequest, PrintService } from '../model/PrintService';
import {
  EscPrColorMode,
  EscPrDpi,
  EscPrJobOptions,
  EscPrMediaType,
  EscPrQuality
} from '../model/EscPrEncoder';
import { Constants, PaperSpec } from '../common/Constants';
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
  @State paperIndex: number = 0;
  @State qualityIndex: number = 0;
  @State mediaIndex: number = 0;
  @State colorIndex: number = 0;
  private service: PrintService = new PrintService();
  private discovery: PrinterDiscovery = new PrinterDiscovery();

  /** 纸张选项与规格一一对应 */
  private paperSpecs: PaperSpec[] = [
    Constants.PAPER_A4,
    Constants.PAPER_LETTER,
    Constants.PAPER_A5,
    Constants.PAPER_POSTCARD,
    Constants.PAPER_4X6,
    Constants.PAPER_5X7
  ];
  private paperOptions: SelectOption[] = [
    { value: 'A4' },
    { value: 'Letter' },
    { value: 'A5' },
    { value: '明信片 100×148' },
    { value: '4×6 照片' },
    { value: '5×7 照片' }
  ];
  private qualityOptions: SelectOption[] = [
    { value: '标准（360dpi）' },
    { value: '高质量（720dpi）' }
  ];
  /** 介质选项与 ESC/P-R 的 MTID 一一对应 */
  private mediaTypes: number[] = [
    EscPrMediaType.PLAIN,
    EscPrMediaType.PHOTO,
    EscPrMediaType.PREMIUM_GLOSSY,
    EscPrMediaType.MATTE
  ];
  private mediaOptions: SelectOption[] = [
    { value: '普通纸' },
    { value: '照片纸（光面）' },
    { value: '高级光面照片纸' },
    { value: '亚光纸' }
  ];
  private colorOptions: SelectOption[] = [
    { value: '彩色' },
    { value: '黑白' }
  ];

  aboutToAppear(): void {
    PersistentStorage.persistProp('printer_ip', '');
    const saved = AppStorage.get<string>('printer_ip');
    if (saved !== undefined && saved.length > 0) {
      this.ip = saved;
    }
  }

  /** 按界面选择组装 ESC/P-R 作业参数 */
  private buildOptions(): EscPrJobOptions {
    const options = new EscPrJobOptions();
    options.dpi = this.qualityIndex === 1 ? EscPrDpi.HIGH : EscPrDpi.STANDARD;
    options.paper = this.paperSpecs[this.paperIndex];
    options.mediaType = this.mediaTypes[this.mediaIndex];
    // 高分辨率配高质量档，普通纸默认标准档
    options.quality = this.qualityIndex === 1 ? EscPrQuality.HIGH : EscPrQuality.NORMAL;
    options.colorMode = this.colorIndex === 1 ? EscPrColorMode.MONOCHROME : EscPrColorMode.COLOR;
    return options;
  }

  private buildRequest(): PrintRequest {
    const req = new PrintRequest(this.ip, this.buildOptions());
    req.progress = (message: string) => {
      this.status = message;
    };
    return req;
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
      const err = e as BusinessError;
      const detail = (err.message !== undefined && err.message.length > 0) ? err.message : '未知错误';
      hilog.error(0x0000, TAG, 'print task failed: %{public}s', detail);
      this.status = '打印失败：' + detail;
      promptAction.showToast({ message: '打印失败：' + detail });
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
      const err = e as BusinessError;
      hilog.error(0x0000, TAG, 'discovery failed: %{public}s', err.message);
      this.status = '扫描失败，请手动输入 IP';
    } finally {
      this.discovering = false;
    }
  }

  /** 选文件：返回选中的 URI，取消或失败返回空串 */
  private async pickDocument(suffix: string): Promise<string> {
    const docPicker = new picker.DocumentViewPicker();
    const opts = new picker.DocumentSelectOptions();
    opts.maxSelectNumber = 1;
    opts.fileSuffixFilters = [suffix];
    try {
      const uris = await docPicker.select(opts);
      if (uris.length === 0) {
        this.status = '未选择文件';
        return '';
      }
      return uris[0];
    } catch (e) {
      this.status = '已取消选择文件';
      return '';
    }
  }

  private async pickAndPrintText(): Promise<void> {
    if (!this.validateIp()) {
      return;
    }
    const uri = await this.pickDocument('.txt');
    if (uri.length === 0) {
      return;
    }
    let content = '';
    try {
      content = PrintService.readTextFile(uri);
    } catch (e) {
      const err = e as BusinessError;
      this.status = '读取文件失败：' + err.message;
      return;
    }
    if (content.trim().length === 0) {
      this.status = '文件内容为空';
      return;
    }
    await this.runTask(() => this.service.printText(this.buildRequest(), content));
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
    await this.runTask(() => this.service.printPhoto(this.buildRequest(), uri));
  }

  /** 打印 Office：kind ∈ {docx, xlsx} */
  private async pickAndPrintOffice(kind: string): Promise<void> {
    if (!this.validateIp()) {
      return;
    }
    const isWord = kind === 'docx';
    const uri = await this.pickDocument(isWord ? '.docx' : '.xlsx');
    if (uri.length === 0) {
      return;
    }
    if (isWord) {
      await this.runTask(() => this.service.printDocx(this.buildRequest(), uri));
    } else {
      await this.runTask(() => this.service.printXlsx(this.buildRequest(), uri));
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
            .enabled(!this.busy)
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
            .enabled(!this.busy)
            .onSelect((index: number, value: string) => {
              this.qualityIndex = index;
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 8 }) {
          Text('纸张类型')
            .fontSize(13)
            .foregroundColor('#666666')
            .width('100%')
          Select(this.mediaOptions)
            .selected(this.mediaIndex)
            .value(this.mediaOptions[this.mediaIndex].value)
            .width('100%')
            .enabled(!this.busy)
            .onSelect((index: number, value: string) => {
              this.mediaIndex = index;
            })
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Column({ space: 8 }) {
          Text('色彩')
            .fontSize(13)
            .foregroundColor('#666666')
            .width('100%')
          Select(this.colorOptions)
            .selected(this.colorIndex)
            .value(this.colorOptions[this.colorIndex].value)
            .width('100%')
            .enabled(!this.busy)
            .onSelect((index: number, value: string) => {
              this.colorIndex = index;
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
