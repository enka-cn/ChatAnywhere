/**
 * 局域网临时 HTTP 编辑器（「电脑上改技能」）。
 *
 * 事实依据（docs/API_REFERENCE.md §8）：本 SDK 没有现成的 HTTP Server，
 * 用 `@ohos.net.socket` 的 TCPSocketServer 手写极简 HTTP/1.1：
 *   GET  /              → 中文编辑页（每个技能一个文本框）
 *   GET  /api/skills    → 技能清单 JSON 数组
 *   POST /api/skill     → 把一个技能清单 JSON 交给 importManifest（校验+落盘）
 *
 * 安全红线（docs/DEV_GUIDE.md §5）：必须用户手动开启；关闭/页面退出立即释放端口。
 * 明文 HTTP 走裸 TCP，不能用 rcp（rcp 明文被禁，错误码 1007900201）。
 */
import { connection, socket } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SkillSummary, UpgradeResult } from '@app/core_plugin';
import { AppServices } from '../app/AppServices';

const DOMAIN: number = 0x1A2B;
const TAG: string = 'ChatAnyWhere/LanEditor';
const DEFAULT_PORT: number = 8123;
const MAX_REQUEST_CHARS: number = 262144;

/** 启动成功后返回给 UI 的连接信息。 */
export interface LanServerInfo {
  /** 手机在局域网里的地址（取不到时为 127.0.0.1）。 */
  ip: string;
  port: number;
  /** 完整地址，如 http://192.168.1.8:8123 。 */
  url: string;
  /** 给用户看的一句说明（同 Wi-Fi、取不到 IP 时如何排查等）。 */
  note: string;
}

/** 极简 HTTP 请求头解析结果。 */
class HttpHeadInfo {
  method: string = '';
  path: string = '';
  contentLength: number = 0;
}

interface LanApiResult {
  ok: boolean;
  message: string;
}

/**
 * 局域网编辑服务（单例，全应用共用；设置页与技能页都从这里启停）。
 */
export class LanEditorServer {
  private static shared: LanEditorServer | null = null;

  private server: socket.TCPSocketServer | null = null;
  private running: boolean = false;
  private port: number = DEFAULT_PORT;
  private info: LanServerInfo | null = null;
  private conns: Map<number, socket.TCPSocketConnection> = new Map<number, socket.TCPSocketConnection>();

  static get(): LanEditorServer {
    if (LanEditorServer.shared === null) {
      LanEditorServer.shared = new LanEditorServer();
    }
    return LanEditorServer.shared;
  }

  /** 是否正在运行（UI 开关状态以此为准）。 */
  isRunning(): boolean {
    return this.running;
  }

  /** 当前连接信息（未运行时为 null）。 */
  currentInfo(): LanServerInfo | null {
    return this.info;
  }

  /**
   * 启动服务。端口被占用或权限不足时抛出中文 Error。
   * 已运行时直接返回上次的连接信息（幂等）。
   */
  async start(port?: number): Promise<LanServerInfo> {
    if (this.running && this.info !== null) {
      return this.info;
    }
    const wantPort: number = port !== undefined && port > 0 && port < 65536 ? port : DEFAULT_PORT;
    if (this.server !== null) {
      await this.stop();
    }

    const server: socket.TCPSocketServer = socket.constructTCPSocketServerInstance();
    this.server = server;
    server.on('error', (err: BusinessError) => {
      hilog.error(DOMAIN, TAG, 'server error %{public}s: %{public}s', `${err.code}`, err.message);
    });
    server.on('connect', (conn: socket.TCPSocketConnection) => {
      this.handleConnect(conn);
    });

    const address: connection.NetAddress = { address: '0.0.0.0', family: 1, port: wantPort };
    try {
      await server.listen(address);
    } catch (e) {
      const err = e as BusinessError;
      this.server = null;
      this.running = false;
      this.info = null;
      hilog.error(DOMAIN, TAG, 'listen failed %{public}s: %{public}s', `${err.code}`, err.message);
      if (err.code === 2303198) {
        throw new Error(`${wantPort} 端口已经被别的程序占用，先在电脑上关掉占用的程序，或者重启手机后再试`);
      }
      if (err.code === 201) {
        throw new Error('缺少联网权限，无法开启电脑端编辑');
      }
      throw new Error(`电脑端编辑没能启动：${err.message}`);
    }

    this.running = true;
    this.port = wantPort;
    const ip: string = await this.resolveLocalIp();
    const url: string = `http://${ip}:${wantPort}`;
    const note: string = ip === '127.0.0.1'
      ? '没读到手机在 Wi-Fi 里的地址：请先连上 Wi-Fi 再打开这个开关，然后在电脑浏览器打开下面的地址。'
      : '请确保电脑和手机连的是同一个 Wi-Fi，然后在电脑浏览器打开下面的地址。';
    const info: LanServerInfo = { ip: ip, port: wantPort, url: url, note: note };
    this.info = info;
    hilog.info(DOMAIN, TAG, 'lan editor started at %{public}s', url);
    return info;
  }

  /** 关闭服务并释放端口（幂等，页面退出必须调用）。 */
  async stop(): Promise<void> {
    this.running = false;
    this.info = null;
    // 先断开还挂着的浏览器连接，再关监听，避免端口残留
    const list: socket.TCPSocketConnection[] = [];
    this.conns.forEach((conn: socket.TCPSocketConnection) => {
      list.push(conn);
    });
    this.conns.clear();
    for (const conn of list) {
      try {
        await conn.close();
      } catch (e) {
        hilog.warn(DOMAIN, TAG, 'close connection failed');
      }
    }
    const server: socket.TCPSocketServer | null = this.server;
    this.server = null;
    if (server !== null) {
      try {
        await server.close();
        hilog.info(DOMAIN, TAG, 'lan editor stopped');
      } catch (e) {
        const err = e as BusinessError;
        hilog.warn(DOMAIN, TAG, 'close server failed: %{public}s', err.message);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // HTTP 解析与分发
  // ---------------------------------------------------------------------------

  private handleConnect(conn: socket.TCPSocketConnection): void {
    const decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
    const encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
    let acc: string = '';
    let responded: boolean = false;
    this.conns.set(conn.clientId, conn);

    conn.on('message', (info: socket.SocketMessageInfo) => {
      if (responded) {
        return;
      }
      acc += decoder.decodeToString(new Uint8Array(info.message), { stream: true });
      if (acc.length > MAX_REQUEST_CHARS) {
        responded = true;
        this.respond(conn, 413, 'Payload Too Large', 'text/plain; charset=utf-8', '内容太大').catch(() => {
        });
        return;
      }
      const headEnd: number = acc.indexOf('\r\n\r\n');
      if (headEnd < 0) {
        return;
      }
      const head: string = acc.substring(0, headEnd);
      const body: string = acc.substring(headEnd + 4);
      const parsed: HttpHeadInfo = this.parseHead(head);
      const received: number = encoder.encodeInto(body).length;
      if (received < parsed.contentLength) {
        return;
      }
      responded = true;
      this.dispatch(conn, parsed, body).catch((e: Error) => {
        hilog.warn(DOMAIN, TAG, 'dispatch failed: %{public}s', e.message);
      });
    });
    conn.on('close', () => {
      this.conns.delete(conn.clientId);
    });
    conn.on('error', (err: BusinessError) => {
      hilog.warn(DOMAIN, TAG, 'connection error %{public}s', err.message);
      this.conns.delete(conn.clientId);
    });
  }

  private parseHead(head: string): HttpHeadInfo {
    const result: HttpHeadInfo = new HttpHeadInfo();
    const lines: string[] = head.split('\r\n');
    if (lines.length === 0) {
      return result;
    }
    const first: string = lines[0];
    const firstParts: string[] = first.split(' ');
    result.method = firstParts.length > 0 ? firstParts[0].toUpperCase() : '';
    result.path = firstParts.length > 1 ? firstParts[1] : '/';
    const queryIndex: number = result.path.indexOf('?');
    if (queryIndex >= 0) {
      result.path = result.path.substring(0, queryIndex);
    }
    for (const line of lines) {
      const lower: string = line.toLowerCase();
      if (lower.startsWith('content-length:')) {
        const raw: string = line.substring(15).trim();
        const value: number = Number.parseInt(raw, 10);
        result.contentLength = Number.isNaN(value) ? 0 : value;
      }
    }
    return result;
  }

  private async dispatch(conn: socket.TCPSocketConnection, head: HttpHeadInfo, body: string): Promise<void> {
    try {
      if (head.method === 'GET' && (head.path === '/' || head.path === '/index.html')) {
        await this.respondHtml(conn, 200, this.renderEditPage());
        return;
      }
      if (head.method === 'GET' && head.path === '/api/skills') {
        await this.respond(conn, 200, 'OK', 'application/json; charset=utf-8', this.skillsJson());
        return;
      }
      if (head.method === 'POST' && head.path === '/api/skill') {
        const message: string = await this.importSkill(body);
        await this.respond(conn, 200, 'OK', 'application/json; charset=utf-8', message);
        return;
      }
      if (head.path === '/favicon.ico') {
        await this.respond(conn, 204, 'No Content', 'text/plain; charset=utf-8', '');
        return;
      }
      await this.respond(conn, 404, 'Not Found', 'application/json; charset=utf-8',
        this.apiJson(false, '页面不存在'));
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'handle request failed: %{public}s', (e as Error).message);
      await this.respond(conn, 500, 'Internal Server Error', 'application/json; charset=utf-8',
        this.apiJson(false, '手机端处理失败，请稍后再试'));
    }
  }

  private async respondHtml(conn: socket.TCPSocketConnection, status: number, body: string): Promise<void> {
    await this.respond(conn, status, 'OK', 'text/html; charset=utf-8', body);
  }

  private async respond(conn: socket.TCPSocketConnection, status: number, reason: string,
    contentType: string, body: string): Promise<void> {
    const encoder: util.TextEncoder = util.TextEncoder.create('utf-8');
    let bodyBytes: number = 0;
    if (body.length > 0) {
      bodyBytes = encoder.encodeInto(body).length;
    }
    const head: string = `HTTP/1.1 ${status} ${reason}\r\n`
      + `Content-Type: ${contentType}\r\n`
      + `Content-Length: ${bodyBytes}\r\n`
      + 'Cache-Control: no-store\r\n'
      + 'Connection: close\r\n\r\n';
    try {
      await conn.send({ data: head + body });
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'send response failed');
    }
    try {
      await conn.close();
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'close connection failed');
    }
    this.conns.delete(conn.clientId);
  }

  // ---------------------------------------------------------------------------
  // 业务：列技能 / 保存技能
  // ---------------------------------------------------------------------------

  private apiJson(ok: boolean, message: string): string {
    const result: LanApiResult = { ok: ok, message: message };
    return JSON.stringify(result);
  }

  private skillsJson(): string {
    const services = AppServices.get();
    if (!services.hasPlugin()) {
      return this.apiJson(false, '技能模块暂不可用，请先在手机的设置里重试');
    }
    try {
      const kernel = services.requirePlugin().kernel;
      const list: SkillSummary[] = kernel.list();
      const parts: string[] = [];
      for (const one of list) {
        const json: string = kernel.exportManifest(one.id);
        if (json.length > 0) {
          parts.push(json);
        }
      }
      if (parts.length === 0) {
        return '[]';
      }
      return `[${parts.join(',')}]`;
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'list skills failed: %{public}s', (e as Error).message);
      return this.apiJson(false, `读取技能失败：${(e as Error).message}`);
    }
  }

  private async importSkill(body: string): Promise<string> {
    const text: string = body.trim();
    if (text.length === 0) {
      return this.apiJson(false, '没有收到内容');
    }
    const services = AppServices.get();
    if (!services.hasPlugin()) {
      return this.apiJson(false, '技能模块暂不可用，请先在手机的设置里重试');
    }
    try {
      const result: UpgradeResult = await services.requirePlugin().kernel.importManifest(text);
      if (result.ok) {
        const detail: string = result.diffText.length > 0 ? result.diffText : '技能已经保存到手机了';
        return this.apiJson(true, detail);
      }
      const reason: string = result.error !== undefined && result.error.length > 0 ? result.error : '清单没通过检查';
      return this.apiJson(false, reason);
    } catch (e) {
      return this.apiJson(false, `保存失败：${(e as Error).message}`);
    }
  }

  // ---------------------------------------------------------------------------
  // 本机 IP
  // ---------------------------------------------------------------------------

  private async resolveLocalIp(): Promise<string> {
    try {
      const handle: connection.NetHandle = await connection.getDefaultNet();
      const properties: connection.ConnectionProperties = await connection.getConnectionProperties(handle);
      for (const link of properties.linkAddresses) {
        const address: string = link.address.address;
        if (address.length > 0 && address !== '127.0.0.1' && address.indexOf(':') < 0) {
          return address;
        }
      }
    } catch (e) {
      hilog.warn(DOMAIN, TAG, 'read local ip failed: %{public}s', (e as Error).message);
    }
    return '127.0.0.1';
  }

  // ---------------------------------------------------------------------------
  // 编辑页 HTML（中文、零外部依赖）
  // ---------------------------------------------------------------------------

  private renderEditPage(): string {
    return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>任意聊 · 电脑端技能编辑</title>
<style>
body{margin:0;padding:20px;background:#f4f6fa;color:#141821;font-family:-apple-system,"Microsoft YaHei",sans-serif}
h1{font-size:20px;margin:0 0 6px}
.tip{color:#6b7280;font-size:13px;margin:0 0 16px;line-height:1.6}
.card{background:#fff;border-radius:12px;padding:14px;margin:0 0 14px;box-shadow:0 1px 3px rgba(20,24,33,.06)}
.card h2{font-size:15px;margin:0 0 4px}
.desc{color:#6b7280;font-size:12px;margin:0 0 8px;line-height:1.5}
textarea{width:100%;box-sizing:border-box;min-height:220px;padding:10px;border:1px solid #e9ecf2;border-radius:8px;font-family:Consolas,Menlo,monospace;font-size:12px;line-height:1.5;background:#fbfcfe;color:#141821}
.bar{margin-top:8px;display:flex;gap:8px;align-items:center}
button{background:#3b6cff;color:#fff;border:0;border-radius:8px;padding:8px 14px;font-size:13px}
#msg{font-size:13px;color:#a15c00;background:#fff7e6;border-radius:8px;padding:10px;margin:0 0 14px;line-height:1.6;white-space:pre-wrap;word-break:break-all}
</style>
</head>
<body>
<h1>任意聊 · 电脑端技能编辑</h1>
<p class="tip">下面每个技能都可以直接在电脑上改。改完点「保存到手机」，手机会立刻校验并生效；如果格式不对，这里会显示中文原因。改坏了也没关系，手机上还能一键回滚到上一版。</p>
<div id="msg">正在读取手机上的技能…</div>
<div id="list"></div>
<script>
var skills = [];
function render() {
  var box = document.getElementById('list');
  box.innerHTML = '';
  if (!skills.length) {
    box.textContent = '手机上还没有安装技能。';
    return;
  }
  for (var i = 0; i < skills.length; i++) {
    var item = skills[i];
    var card = document.createElement('div');
    card.className = 'card';
    var title = document.createElement('h2');
    title.textContent = (item.name || item.id || '未命名技能') + ' · v' + (item.version || '1');
    card.appendChild(title);
    var desc = document.createElement('p');
    desc.className = 'desc';
    desc.textContent = item.description || '';
    card.appendChild(desc);
    var area = document.createElement('textarea');
    area.value = JSON.stringify(item, null, 2);
    card.appendChild(area);
    var bar = document.createElement('div');
    bar.className = 'bar';
    var btn = document.createElement('button');
    btn.textContent = '保存到手机';
    btn.onclick = function (area, name) {
      return function () {
        var msg = document.getElementById('msg');
        msg.textContent = '正在保存「' + name + '」…';
        fetch('/api/skill', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: area.value })
          .then(function (r) { return r.text(); })
          .then(function (t) {
            try { var data = JSON.parse(t); msg.textContent = (data.ok ? '已保存：' : '没保存成功：') + data.message; }
            catch (e) { msg.textContent = t; }
          })
          .catch(function (e) { msg.textContent = '保存失败：' + e; });
      };
    }(area, title.textContent);
    bar.appendChild(btn);
    card.appendChild(bar);
    box.appendChild(card);
  }
}
function load() {
  fetch('/api/skills')
    .then(function (r) { return r.text(); })
    .then(function (t) {
      var msg = document.getElementById('msg');
      try {
        var data = JSON.parse(t);
        if (Object.prototype.toString.call(data) === '[object Array]') {
          skills = data;
          msg.textContent = '共读到 ' + data.length + ' 个技能。改完记得点每张卡片里的「保存到手机」。';
        } else {
          skills = [];
          msg.textContent = data.message || '读取失败';
        }
      } catch (e) {
        skills = [];
        msg.textContent = '读取失败，请刷新页面';
      }
      render();
    })
    .catch(function (e) { document.getElementById('msg').textContent = '连不上手机：' + e; });
}
load();
</script>
</body>
</html>`;
  }
}
