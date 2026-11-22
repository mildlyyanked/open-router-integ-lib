/** Removes ```json fences some models wrap around JSON. */
export function stripFences(text: string): string {
  let t = text.trim();
  if (t.startsWith("```")) {
    const nl = t.indexOf("\n");
    t = nl >= 0 ? t.slice(nl + 1) : t;
    if (t.endsWith("```")) t = t.slice(0, -3);
  }
  return t.trim();
}

/** JSON.parse that returns undefined instead of throwing; tolerates fences. */
export function parseJson(text: string): unknown {
  try {
    return JSON.parse(stripFences(text));
  } catch {
    return undefined;
  }
}

/** JSON with sorted keys (stable across runs). */
export function canonical(v: unknown): string {
  return JSON.stringify(sortKeys(v));
}

function sortKeys(v: unknown): unknown {
  if (Array.isArray(v)) return v.map(sortKeys);
  if (v && typeof v === "object") {
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(v).sort()) out[k] = sortKeys((v as Record<string, unknown>)[k]);
    return out;
  }
  return v;
}

/** 64-bit FNV-1a as 16 hex chars: a sync, dependency-free key for fixtures and caches. */
export function hashKey(v: unknown): string {
  const s = canonical(v);
  let h = 0xcbf29ce484222325n;
  const p = 0x100000001b3n;
  for (let i = 0; i < s.length; i++) {
    h ^= BigInt(s.charCodeAt(i));
    h = (h * p) & 0xffffffffffffffffn;
  }
  return h.toString(16).padStart(16, "0");
}
