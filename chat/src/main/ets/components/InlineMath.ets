/**
 * LaTeX → 行内可读文本的轻量映射（v3.8）。
 *
 * 纯逻辑、零 import：`MarkdownBlock` 用它在行内公式 Span 里做「类公式排版」，
 * 同时也能被 `tools/logic-tests` 的 Node 直接跑。
 *
 * v3.8 修复（真机截图反馈）：
 * - 单遍递归扫描：命令先剥壳（读取完整命令名，天然等价 `(?![a-zA-Z])` 边界），
 *   上下标内容先递归 `latexToText` 再映射，避免 `e^\xi`、`\lim_{x\to 0}` 残留反斜杠；
 * - 标准函数名（sin/cos/tan/…/lim/max/min…）输出正体文本；\text/\mathrm/... 递归取内容；
 *   \left \right \, \; \! \quad \qquad \displaystyle \limits 清理；
 * - \frac 括号优化：单数字/单字母/简单幂（1、24、x、x²）不加括号，复杂才 (a)/(b)；
 * - 未知命令保留源码（便于排查），标准命令输出绝不残留裸 `\`。
 */

/** 符号表（命令名 → 显示字符）。 */
function buildSymbols(): Map<string, string> {
  const map: Map<string, string> = new Map<string, string>();
  // 希腊字母（小写）
  map.set('alpha', 'α');
  map.set('beta', 'β');
  map.set('gamma', 'γ');
  map.set('delta', 'δ');
  map.set('epsilon', 'ε');
  map.set('varepsilon', 'ε');
  map.set('zeta', 'ζ');
  map.set('eta', 'η');
  map.set('theta', 'θ');
  map.set('vartheta', 'ϑ');
  map.set('iota', 'ι');
  map.set('kappa', 'κ');
  map.set('lambda', 'λ');
  map.set('mu', 'μ');
  map.set('nu', 'ν');
  map.set('xi', 'ξ');
  map.set('pi', 'π');
  map.set('rho', 'ρ');
  map.set('sigma', 'σ');
  map.set('tau', 'τ');
  map.set('upsilon', 'υ');
  map.set('phi', 'φ');
  map.set('varphi', 'φ');
  map.set('chi', 'χ');
  map.set('psi', 'ψ');
  map.set('omega', 'ω');
  // 希腊字母（大写）
  map.set('Gamma', 'Γ');
  map.set('Delta', 'Δ');
  map.set('Theta', 'Θ');
  map.set('Lambda', 'Λ');
  map.set('Xi', 'Ξ');
  map.set('Pi', 'Π');
  map.set('Sigma', 'Σ');
  map.set('Phi', 'Φ');
  map.set('Psi', 'Ψ');
  map.set('Omega', 'Ω');
  // 常见运算符 / 关系符
  map.set('times', '×');
  map.set('cdot', '·');
  map.set('div', '÷');
  map.set('pm', '±');
  map.set('mp', '∓');
  map.set('leq', '≤');
  map.set('le', '≤');
  map.set('geq', '≥');
  map.set('ge', '≥');
  map.set('neq', '≠');
  map.set('ne', '≠');
  map.set('approx', '≈');
  map.set('equiv', '≡');
  map.set('sim', '∼');
  map.set('simeq', '≃');
  map.set('propto', '∝');
  map.set('infty', '∞');
  map.set('partial', '∂');
  map.set('nabla', '∇');
  map.set('sum', 'Σ');
  map.set('prod', 'Π');
  map.set('int', '∫');
  map.set('iint', '∬');
  map.set('oint', '∮');
  map.set('to', '→');
  map.set('rightarrow', '→');
  map.set('leftarrow', '←');
  map.set('leftrightarrow', '↔');
  map.set('Rightarrow', '⇒');
  map.set('Leftarrow', '⇐');
  map.set('Leftrightarrow', '⇔');
  map.set('mapsto', '↦');
  map.set('in', '∈');
  map.set('notin', '∉');
  map.set('subset', '⊂');
  map.set('supset', '⊃');
  map.set('subseteq', '⊆');
  map.set('cup', '∪');
  map.set('cap', '∩');
  map.set('forall', '∀');
  map.set('exists', '∃');
  map.set('neg', '¬');
  map.set('land', '∧');
  map.set('lor', '∨');
  map.set('angle', '∠');
  map.set('degree', '°');
  map.set('circ', '∘');
  map.set('perp', '⊥');
  map.set('parallel', '∥');
  map.set('ldots', '…');
  map.set('dots', '…');
  map.set('cdots', '⋯');
  map.set('vdots', '⋮');
  map.set('prime', '′');
  map.set('hbar', 'ℏ');
  map.set('ell', 'ℓ');
  map.set('emptyset', '∅');
  map.set('varnothing', '∅');
  map.set('because', '∵');
  map.set('therefore', '∴');
  map.set('langle', '⟨');
  map.set('rangle', '⟩');
  map.set('lfloor', '⌊');
  map.set('rfloor', '⌋');
  map.set('lceil', '⌈');
  map.set('rceil', '⌉');
  return map;
}

const SYMBOLS: Map<string, string> = buildSymbols();

/** 数学函数名（去掉反斜杠输出正体文本）。 */
function buildFunctions(): Map<string, string> {
  const map: Map<string, string> = new Map<string, string>();
  map.set('arcsin', 'arcsin');
  map.set('arccos', 'arccos');
  map.set('arctan', 'arctan');
  map.set('sinh', 'sinh');
  map.set('cosh', 'cosh');
  map.set('tanh', 'tanh');
  map.set('sin', 'sin');
  map.set('cos', 'cos');
  map.set('tan', 'tan');
  map.set('cot', 'cot');
  map.set('sec', 'sec');
  map.set('csc', 'csc');
  map.set('ln', 'ln');
  map.set('log', 'log');
  map.set('lg', 'lg');
  map.set('exp', 'exp');
  map.set('lim', 'lim');
  map.set('max', 'max');
  map.set('min', 'min');
  map.set('sup', 'sup');
  map.set('inf', 'inf');
  map.set('det', 'det');
  map.set('gcd', 'gcd');
  map.set('mod', 'mod');
  return map;
}

const FUNCTIONS: Map<string, string> = buildFunctions();

/** 直接清理（不产生字符）的排版命令。 */
function isCleanupCommand(name: string): boolean {
  return name === 'left' || name === 'right' || name === 'bigl' || name === 'bigr'
    || name === 'Bigl' || name === 'Bigr' || name === 'biggl' || name === 'biggr'
    || name === 'displaystyle' || name === 'textstyle' || name === 'limits'
    || name === 'nolimits' || name === 'mathstrut' || name === 'strut';
}

/** 上标字符表。 */
function buildSuperscripts(): Map<string, string> {
  const map: Map<string, string> = new Map<string, string>();
  map.set('0', '⁰');
  map.set('1', '¹');
  map.set('2', '²');
  map.set('3', '³');
  map.set('4', '⁴');
  map.set('5', '⁵');
  map.set('6', '⁶');
  map.set('7', '⁷');
  map.set('8', '⁸');
  map.set('9', '⁹');
  map.set('+', '⁺');
  map.set('-', '⁻');
  map.set('=', '⁼');
  map.set('(', '⁽');
  map.set(')', '⁾');
  map.set('n', 'ⁿ');
  map.set('i', 'ⁱ');
  map.set('x', 'ˣ');
  map.set('T', 'ᵀ');
  map.set('a', 'ᵃ');
  map.set('b', 'ᵇ');
  map.set('c', 'ᶜ');
  map.set('k', 'ᵏ');
  map.set('m', 'ᵐ');
  map.set('p', 'ᵖ');
  map.set('t', 'ᵗ');
  return map;
}

/** 下标字符表。 */
function buildSubscripts(): Map<string, string> {
  const map: Map<string, string> = new Map<string, string>();
  map.set('0', '₀');
  map.set('1', '₁');
  map.set('2', '₂');
  map.set('3', '₃');
  map.set('4', '₄');
  map.set('5', '₅');
  map.set('6', '₆');
  map.set('7', '₇');
  map.set('8', '₈');
  map.set('9', '₉');
  map.set('+', '₊');
  map.set('-', '₋');
  map.set('=', '₌');
  map.set('(', '₍');
  map.set(')', '₎');
  map.set('a', 'ₐ');
  map.set('e', 'ₑ');
  map.set('i', 'ᵢ');
  map.set('o', 'ₒ');
  map.set('u', 'ᵤ');
  map.set('x', 'ₓ');
  map.set('n', 'ₙ');
  map.set('k', 'ₖ');
  map.set('m', 'ₘ');
  map.set('j', 'ⱼ');
  map.set('t', 'ₜ');
  return map;
}

const SUPERSCRIPTS: Map<string, string> = buildSuperscripts();
const SUBSCRIPTS: Map<string, string> = buildSubscripts();

/** 是否 ASCII 字母。 */
function isLetter(ch: string): boolean {
  return (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z');
}

/** 是否 Unicode 上下标字符（仅用于「简单幂」判定，不把 ASCII 字母/运算符当上标）。 */
function isScriptChar(ch: string): boolean {
  const code: number = ch.charCodeAt(0);
  // ¹ U+00B9、²~³ U+00B2~B3、上标/下标区 U+2070~U+209F
  return code === 0x00b9 || (code >= 0x00b2 && code <= 0x00b3) || (code >= 0x2070 && code <= 0x209f);
}

/** 从 start（应为 `{`）读取一个花括号分组；返回 [内容, 结束后下标]；失败返回 []。 */
function readGroup(text: string, start: number): string[] {
  const out: string[] = [];
  if (start >= text.length || text.charAt(start) !== '{') {
    return out;
  }
  let depth: number = 0;
  let i: number = start;
  while (i < text.length) {
    const ch: string = text.charAt(i);
    if (ch === '{') {
      depth += 1;
      if (depth > 1) {
        out.push(ch);
      }
      i += 1;
      continue;
    }
    if (ch === '}') {
      depth -= 1;
      if (depth === 0) {
        const result: string[] = [out.join(''), `${i + 1}`];
        return result;
      }
      out.push(ch);
      i += 1;
      continue;
    }
    out.push(ch);
    i += 1;
  }
  return out;
}

/** 读取脚本参数（`{...}` / 单字符 / 不带花括号的完整命令如 ^\xi）；返回 [内容, 结束后下标]。 */
function readScript(text: string, start: number): string[] {
  if (start >= text.length) {
    return [];
  }
  if (text.charAt(start) === '{') {
    return readGroup(text, start);
  }
  // 不带花括号的命令（e^\xi）：整条命令作为一个脚本内容
  if (text.charAt(start) === '\\') {
    let k: number = start + 1;
    while (k < text.length && isLetter(text.charAt(k))) {
      k += 1;
    }
    if (k > start + 1) {
      return [text.substring(start, k), `${k}`];
    }
  }
  return [text.charAt(start), `${start + 1}`];
}

/** 单个操作数是否「简单」（1、24、x、x²、x₁）→ \frac 不加括号。 */
function isSimpleOperand(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  if (new RegExp('^[0-9]+$').test(text)) {
    return true;
  }
  if (text.length === 1 && isLetter(text)) {
    return true;
  }
  if (text.length >= 2 && isLetter(text.charAt(0))) {
    let allScript: boolean = true;
    for (let i = 1; i < text.length; i++) {
      if (!isScriptChar(text.charAt(i))) {
        allScript = false;
        break;
      }
    }
    if (allScript) {
      return true;
    }
  }
  return false;
}

/** 上下标内容 → 显示文本（内容需已递归转换）。 */
function mapScript(content: string, superscript: boolean): string {
  if (content.length === 0) {
    return '';
  }
  const table: Map<string, string> = superscript ? SUPERSCRIPTS : SUBSCRIPTS;
  const prefix: string = superscript ? '^' : '_';
  if (content.length === 1) {
    const mapped: string | undefined = table.get(content);
    return mapped !== undefined ? mapped : `${prefix}${content}`;
  }
  let all: string = '';
  let allMapped: boolean = true;
  for (let i = 0; i < content.length; i++) {
    const ch: string = content.charAt(i);
    const mapped: string | undefined = table.get(ch);
    if (mapped === undefined) {
      allMapped = false;
      break;
    }
    all += mapped;
  }
  if (allMapped) {
    return all;
  }
  return `${prefix}(${content})`;
}

/**
 * LaTeX → 行内近似文本。
 *
 * 例：`\frac{1}{24}` → `1/24`；`x^2` → `x²`；`\sin x` → `sin x`；
 * `\lim_{x\to 0}` → `lim_(x→ 0)`。
 */
export function latexToText(latex: string): string {
  if (latex === undefined || latex === null || latex.length === 0) {
    return '';
  }
  let out: string = '';
  let i: number = 0;
  while (i < latex.length) {
    const ch: string = latex.charAt(i);

    // 控制序列（读取完整命令名：等价命令边界 (?![a-zA-Z])）
    if (ch === '\\') {
      let j: number = i + 1;
      while (j < latex.length && isLetter(latex.charAt(j))) {
        j += 1;
      }
      const name: string = latex.substring(i + 1, j);
      if (name.length === 0) {
        // \\ / \{ \} \% \_ \# \& \$ \, \; \! \  等单字符命令
        const escaped: string = latex.charAt(j);
        if (escaped === '\\' || escaped === '' || escaped === ' ') {
          out += ' ';
          i = j + 1;
          continue;
        }
        if (escaped === ',' || escaped === ';' || escaped === ':') {
          out += ' ';
          i = j + 1;
          continue;
        }
        if (escaped === '!') {
          i = j + 1;
          continue;
        }
        out += escaped;
        i = j + 1;
        continue;
      }

      // 分数：操作数先递归转换，简单操作数不加括号
      if (name === 'frac' || name === 'dfrac' || name === 'tfrac') {
        const first: string[] = readGroup(latex, j);
        if (first.length === 2) {
          const second: string[] = readGroup(latex, Number.parseInt(first[1]));
          if (second.length === 2) {
            const top: string = latexToText(first[0]);
            const bottom: string = latexToText(second[0]);
            const topText: string = isSimpleOperand(top) ? top : `(${top})`;
            const bottomText: string = isSimpleOperand(bottom) ? bottom : `(${bottom})`;
            out += `${topText}/${bottomText}`;
            i = Number.parseInt(second[1]);
            continue;
          }
        }
      }

      // 根号：\sqrt[n]{x} 或 \sqrt{x}
      if (name === 'sqrt') {
        let cursor: number = j;
        let indexText: string = '';
        if (cursor < latex.length && latex.charAt(cursor) === '[') {
          const closeBracket: number = latex.indexOf(']', cursor + 1);
          if (closeBracket > cursor + 1) {
            indexText = latexToText(latex.substring(cursor + 1, closeBracket));
            cursor = closeBracket + 1;
          }
        }
        const group: string[] = readGroup(latex, cursor);
        if (group.length === 2) {
          const body: string = latexToText(group[0]);
          const bodyText: string = isSimpleOperand(body) ? body : `(${body})`;
          out += indexText.length > 0 ? `${indexText}√${bodyText}` : `√${bodyText}`;
          i = Number.parseInt(group[1]);
          continue;
        }
      }

      // 文本类命令：取花括号内文本（递归转换）
      if (name === 'text' || name === 'mathrm' || name === 'mathbf' || name === 'mathit'
        || name === 'textbf' || name === 'operatorname') {
        const group: string[] = readGroup(latex, j);
        if (group.length === 2) {
          out += latexToText(group[0]);
          i = Number.parseInt(group[1]);
          continue;
        }
      }

      // 环境标记：\begin{aligned} / \end{aligned} 直接跳过
      if (name === 'begin' || name === 'end') {
        const group: string[] = readGroup(latex, j);
        if (group.length === 2) {
          i = Number.parseInt(group[1]);
          continue;
        }
      }

      // 空白 / 排版控制命令
      if (name === 'quad') {
        out += '  ';
        i = j;
        continue;
      }
      if (name === 'qquad') {
        out += '    ';
        i = j;
        continue;
      }
      if (isCleanupCommand(name)) {
        i = j;
        continue;
      }

      // 数学函数名：输出正体文本
      const fn: string | undefined = FUNCTIONS.get(name);
      if (fn !== undefined) {
        out += fn;
        i = j;
        continue;
      }

      // 希腊字母 / 运算符
      const mapped: string | undefined = SYMBOLS.get(name);
      if (mapped !== undefined) {
        out += mapped;
        i = j;
        continue;
      }

      // 未知命令：保留源码，便于排查，不丢信息
      out += `\\${name}`;
      i = j;
      continue;
    }

    // 上下标：内容先递归转换，再做映射（保证 e^{\xi} 不残留反斜杠）
    if (ch === '^' || ch === '_') {
      const script: string[] = readScript(latex, i + 1);
      if (script.length === 2) {
        const inner: string = latexToText(script[0]);
        out += mapScript(inner, ch === '^');
        i = Number.parseInt(script[1]);
        continue;
      }
    }

    // 分组花括号 / 对齐符号：只留内容
    if (ch === '{' || ch === '}') {
      i += 1;
      continue;
    }
    if (ch === '&') {
      out += ' ';
      i += 1;
      continue;
    }
    out += ch;
    i += 1;
  }
  return out;
}
