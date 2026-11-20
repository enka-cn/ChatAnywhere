/**
 * core_protocol 纯工具：标题兜底 / 错误中文化 / URL 拼接
 * （util/TitleUtil.ets、util/ErrorText.ets、util/UrlUtil.ets）
 *
 * 对应 Milestone 1 DoD「实时显示自动生成的会话标题」与 §6 质量线「中文直白文案」。
 */
import { test, assert, skip, summarize } from './_harness.mjs';
import { tryImport, missingReason } from './_paths.mjs';

const TITLE_P = 'packages/core_protocol/src/main/ets/util/TitleUtil.ts';
const ERROR_P = 'packages/core_protocol/src/main/ets/util/ErrorText.ts';
const URL_P = 'packages/core_protocol/src/main/ets/util/UrlUtil.ts';
const [T, E, U] = await Promise.all([tryImport(TITLE_P), tryImport(ERROR_P), tryImport(URL_P)]);

if (!T) {
  skip('标题工具（全部用例）', missingReason(TITLE_P));
} else {
  test('[Title] sanitizeTitleText 去掉 Markdown 符号并压缩空白', () => {
    assert.equal(T.sanitizeTitleText('## 标题 **加粗**'), '标题 加粗');
    assert.equal(T.sanitizeTitleText('第一行\n\n第二行'), '第一行 第二行');
    assert.equal(T.sanitizeTitleText('```code```'), 'code');
    assert.equal(T.sanitizeTitleText('，开头的标点会被去掉'), '开头的标点会被去掉');
    assert.equal(T.sanitizeTitleText(''), '');
    assert.equal(T.sanitizeTitleText(null), '');
  });

  test('[Title] truncateTitle 超长截断并补省略号', () => {
    assert.equal(T.truncateTitle('短标题', 16), '短标题');
    const long = '一二三四五六七八九十一二三四五六七八';
    assert.equal(T.truncateTitle(long, 16), long.substring(0, 16) + '…');
    assert.equal(T.truncateTitle('  ', 5), '');
  });

  test('[Title] buildLocalTitle 优先首条用户提问，取第一句', () => {
    assert.equal(T.buildLocalTitle('小米和大米有什么区别？', ''), '小米和大米有什么区别');
    assert.equal(T.buildLocalTitle('第一句。第二句', ''), '第一句');
  });

  test('[Title] buildLocalTitle 超长截断到 16 字；用户为空时回退助手回答（整句截长）', () => {
    const long = '这是一个非常非常长的用户提问内容需要被截断处理';
    const title = T.buildLocalTitle(long, '');
    assert.equal(title.length, 17); // 16 + '…'
    assert.ok(title.endsWith('…'));
    // 助手兜底路径不做「取第一句」，只按长度截断
    assert.equal(T.buildLocalTitle('', '助手的第一句回答。后续'), '助手的第一句回答。后续');
  });

  test('[Title] buildLocalTitle 两者都为空时返回「新的对话」', () => {
    assert.equal(T.buildLocalTitle('', ''), '新的对话');
    assert.equal(T.buildLocalTitle(null, null), '新的对话');
  });
}

if (!E) {
  skip('错误中文化（全部用例）', missingReason(ERROR_P));
} else {
  test('[ErrorText] rcp 业务码 → 直白中文 + 可重试标记', () => {
    assert.ok(E.mapRcpError(1007900007, '').message.includes('连不上服务器'));
    assert.equal(E.mapRcpError(1007900007, '').retriable, true);
    assert.ok(E.mapRcpError(1007900028, '').message.includes('超时'));
    assert.equal(E.mapRcpError(1007900009, '').retriable, false);
    assert.ok(E.mapRcpError(1007900201, '').message.includes('https'));
    assert.equal(E.mapRcpError(1007900201, '').retriable, false);
    assert.equal(E.mapRcpError(1007900007, '').errorCode, 'rcp_1007900007');
  });

  test('[ErrorText] 未知 rcp 码：带原始信息时拼接，不带时给通用中文', () => {
    const withDetail = E.mapRcpError(1999999999, 'something odd');
    assert.ok(withDetail.message.includes('something odd'));
    const noDetail = E.mapRcpError(1999999999, '');
    assert.ok(noDetail.message.includes('网络请求失败'));
    assert.equal(noDetail.retriable, true);
  });

  test('[ErrorText] HTTP 状态码中文化（401/402/404/429/500 等）', () => {
    assert.ok(E.mapHttpStatus(401, '').message.includes('密钥'));
    assert.equal(E.mapHttpStatus(401, '').retriable, false);
    assert.ok(E.mapHttpStatus(402, '').message.includes('余额不足'));
    assert.ok(E.mapHttpStatus(404, '').message.includes('接口地址不存在'));
    assert.equal(E.mapHttpStatus(429, '').retriable, true);
    assert.equal(E.mapHttpStatus(503, '').retriable, true);
    assert.equal(E.mapHttpStatus(400, '').retriable, false);
  });

  test('[ErrorText] 未知 HTTP 状态：短响应体带上细节，长响应体只给状态码', () => {
    const short = E.mapHttpStatus(418, 'tea pot');
    assert.ok(short.message.includes('418'));
    assert.ok(short.message.includes('tea pot'));
    const long = E.mapHttpStatus(418, 'x'.repeat(500));
    assert.ok(!long.message.includes('xxxxx'));
  });

  test('[ErrorText] mapThrownError 能从 BusinessError 文本里提取 rcp 码', () => {
    const fromRcp = E.mapThrownError('BusinessError: rcp error 1007900007: connection refused');
    assert.ok(fromRcp.message.includes('连不上服务器'));
    const generic = E.mapThrownError('随便一个异常');
    assert.ok(generic.message.includes('网络请求失败'));
    assert.equal(generic.retriable, true);
    assert.equal(E.mapThrownError('').errorCode, 'unknown');
  });
}

if (!U) {
  skip('URL 工具（全部用例）', missingReason(URL_P));
} else {
  test('[UrlUtil] joinUrl：去尾部斜杠、避免重复路径、支持子路径 baseUrl', () => {
    assert.equal(U.joinUrl('https://api.deepseek.com', '/responses'), 'https://api.deepseek.com/responses');
    assert.equal(U.joinUrl('https://api.deepseek.com/', '/responses'), 'https://api.deepseek.com/responses');
    assert.equal(U.joinUrl('https://api.deepseek.com/responses', '/responses'),
      'https://api.deepseek.com/responses');
    assert.equal(U.joinUrl('https://example.com/openai/v1', '/chat/completions'),
      'https://example.com/openai/v1/chat/completions');
    assert.equal(U.joinUrl('', '/v1/messages'), '/v1/messages');
    assert.equal(U.joinUrl('https://x.com', 'v1/messages'), 'https://x.com/v1/messages');
  });

  test('[UrlUtil] isHttpsUrl 判定（rcp 禁止明文 HTTP）', () => {
    assert.equal(U.isHttpsUrl('https://api.deepseek.com'), true);
    assert.equal(U.isHttpsUrl('  HTTPS://api.deepseek.com '), true);
    assert.equal(U.isHttpsUrl('http://api.deepseek.com'), false);
    assert.equal(U.isHttpsUrl(''), false);
    assert.equal(U.isHttpsUrl(null), false);
  });

  test('[UrlUtil] bodySnippet 去换行并截断', () => {
    assert.equal(U.bodySnippet('第一行\n第二行', 100), '第一行 第二行');
    const snip = U.bodySnippet('x'.repeat(50), 10);
    assert.equal(snip.length, 11);
    assert.ok(snip.endsWith('…'));
    assert.equal(U.bodySnippet('', 10), '');
    assert.equal(U.bodySnippet(null, 10), '');
  });
}

summarize();
