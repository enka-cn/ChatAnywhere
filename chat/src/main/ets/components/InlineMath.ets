/**
 * LaTeX → 行内可读文本的轻量映射（v3.7）。
 *
 * 纯逻辑、零 import：`MarkdownBlock` 用它在行内公式 Span 里做「类公式排版」，
 * 同时也能被 `tools/logic-tests` 的 Node 直接跑。
 *
 * 原则：
 * - 希腊字母 / 常见运算符 / 上下标 → Unicode；
 * - 分数、根号、\text{} 等带参数命令做结构化展开；
 * - 未知命令保留源码（`\foo`），不丢信息；
 * - 跳过 aligned 环境标记、`&`、`\\` 等排版控制符。
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

/** 从 start（应为 `{`）读取一个花括号分组；返回内容与结束后下标。 */
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

/** 读取脚本参数：`{...}` 分组或单个字符；返回内容与结束后下标。 */
function readScript(text: string, start: number): string[] {
  if (start >= text.length) {
    return [];
  }
  if (text.charAt(start) === '{') {
    return readGroup(text, start);
  }
  return [text.charAt(start), `${start + 1}`];
}

/** 把内容映射成上/下标；无法映射的保留原样。 */
function mapScript(content: string, table: Map<string, string>, prefix: string): string {
  let out: string = '';
  for (let i = 0; i < content.length; i++) {
    const ch: string = content.charAt(i);
    const mapped: string | undefined = table.get(ch);
    if (mapped !== undefined) {
      out += mapped;
    } else {
      out += ch;
    }
  }
  if (out === content) {
    return `${prefix}${content}`;
  }
  return out;
}

/**
 * LaTeX → 行内近似文本。
 *
 * 例：`\frac{a}{b}` → `(a)/(b)`；`x^2` → `x²`；`\alpha \le \beta` → `α ≤ β`。
 */
export function latexToText(latex: string): string {
  if (latex === undefined || latex === null || latex.length === 0) {
    return '';
  }
  let out: string = '';
  let i: number = 0;
  while (i < latex.length) {
    const ch: string = latex.charAt(i);

    // 控制序列
    if (ch === '\\') {
      let j: number = i + 1;
      while (j < latex.length && isLetter(latex.charAt(j))) {
        j += 1;
      }
      const name: string = latex.substring(i + 1, j);
      if (name.length === 0) {
        // \\（换行）/ \{ \} \% \_ \# \& \$ 等单字符命令
        const escaped: string = latex.charAt(j);
        if (escaped === '\\' || escaped === '' || escaped === ' ') {
          out += ' ';
          i = j + 1;
          continue;
        }
        out += escaped;
        i = j + 1;
        continue;
      }
      // 分数
      if (name === 'frac' || name === 'dfrac' || name === 'tfrac') {
        const g1: string[] = readGroup(latex, j);
        if (g1.length === 2) {
          const nextIndex: number = Number.parseInt(g1[1]);
          const g2: string[] = readGroup(latex, nextIndex);
          const top: string = latexToText(g1[0]);
          const bottom: string = g2.length === 2 ? latexToText(g2[0]) : '';
          out += bottom.length > 0 ? `(${top})/(${bottom})` : `(${top})`;
          i = g2.length === 2 ? Number.parseInt(g2[1]) : nextIndex;
          continue;
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
        const body: string = group.length === 2 ? latexToText(group[0]) : '';
        if (body.length > 0) {
          out += indexText.length > 0 ? `${indexText}√(${body})` : `√(${body})`;
          i = group.length === 2 ? Number.parseInt(group[1]) : cursor;
          continue;
        }
      }
      // 文本类命令：只取内容
      if (name === 'text' || name === 'mathrm' || name === 'mathbf' || name === 'mathit'
        || name === 'operatorname' || name === 'textbf') {
        const group: string[] = readGroup(latex, j);
        if (group.length === 2) {
          out += group[0];
          i = Number.parseInt(group[1]);
          continue;
        }
      }
      // 环境标记 / 排版控制：跳过
      if (name === 'begin' || name === 'end') {
        const group: string[] = readGroup(latex, j);
        if (group.length === 2) {
          i = Number.parseInt(group[1]);
          continue;
        }
      }
      if (name === 'left' || name === 'right' || name === 'bigl' || name === 'bigr'
        || name === 'Bigl' || name === 'Bigr' || name === 'displaystyle' || name === 'textstyle') {
        i = j;
        continue;
      }
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
      if (name === ' ' || name === ',' || name === ';' || name === ':' || name === '!') {
        out += ' ';
        i = j;
        continue;
      }
      const mapped: string | undefined = SYMBOLS.get(name);
      if (mapped !== undefined) {
        out += mapped;
        i = j;
        continue;
      }
      // 未知命令：保留源码，不丢信息
      out += `\\${name}`;
      i = j;
      continue;
    }

    // 上下标
    if (ch === '^' || ch === '_') {
      const script: string[] = readScript(latex, i + 1);
      if (script.length === 2) {
        const content: string = script[0];
        if (ch === '^') {
          out += mapScript(content, SUPERSCRIPTS, '^');
        } else {
          out += mapScript(content, SUBSCRIPTS, '_');
        }
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
