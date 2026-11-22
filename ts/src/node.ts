import { readFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import { join, dirname } from "node:path";
import type { PromptSource } from "./prompts.js";

/** Loads a prompts folder laid out like the Godot addon's (same files work for both). */
export function loadPromptsFromDir(root: string): PromptSource {
  const cache = new Map<string, string | undefined>();
  const read = (p: string): string | undefined => {
    if (!cache.has(p)) cache.set(p, existsSync(p) ? readFileSync(p, "utf8") : undefined);
    return cache.get(p);
  };
  return {
    template: (uc, v) => read(join(root, uc, `v${v}.md`)),
    schema: (uc) => {
      const t = read(join(root, uc, "schema.json"));
      return t ? (JSON.parse(t) as Record<string, unknown>) : undefined;
    },
    shared: (n) => read(join(root, "_shared", `${n}.md`)),
  };
}

/** Fixture files on disk for MockProvider / RecordingProvider: <dir>/<use_case>/<key>.json */
export function fileFixtures(dir: string) {
  return {
    load(useCase: string, key: string): unknown {
      const p = join(dir, useCase, `${key}.json`);
      return existsSync(p) ? JSON.parse(readFileSync(p, "utf8")) : undefined;
    },
    save(useCase: string, key: string, fixture: unknown): void {
      const p = join(dir, useCase, `${key}.json`);
      mkdirSync(dirname(p), { recursive: true });
      writeFileSync(p, JSON.stringify(fixture, null, 2));
    },
  };
}

/** Adapts a web-standard handler (e.g. createOpenRouterProxy) to Node's http / Express (req, res). */
export function toNodeHandler(handler: (req: Request) => Promise<Response>) {
  return async (req: import("node:http").IncomingMessage, res: import("node:http").ServerResponse): Promise<void> => {
    const chunks: Buffer[] = [];
    for await (const c of req) chunks.push(c as Buffer);
    const url = `http://${req.headers.host ?? "localhost"}${req.url ?? "/"}`;
    const headers = new Headers();
    for (const [k, v] of Object.entries(req.headers)) if (typeof v === "string") headers.set(k, v);
    const body = req.method === "GET" || req.method === "HEAD" ? undefined : Buffer.concat(chunks);
    const r = await handler(new Request(url, { method: req.method, headers, body }));
    res.writeHead(r.status, Object.fromEntries(r.headers.entries()));
    if (r.body) {
      const reader = r.body.getReader();
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        res.write(value);
      }
    }
    res.end();
  };
}
