import { type APIRequestContext } from "@playwright/test";
import { spawnSync } from "node:child_process";

export const PASSWORD = "ValidP@ssword123!";

export const USERS = {
  admin: { email: "dav-admin@carddav.test", password: PASSWORD },
  editor: { email: "dav-editor@carddav.test", password: PASSWORD },
  viewer: { email: "dav-viewer@carddav.test", password: PASSWORD },
  other: { email: "dav-other@carddav.test", password: PASSWORD },
  totp: { email: "dav-totp@carddav.test", password: PASSWORD },
  unconfirmed: { email: "dav-unconfirmed@carddav.test", password: PASSWORD },
  perf: { email: "dav-perf@carddav.test", password: PASSWORD },
} satisfies Record<string, { email: string; password: string }>;

export type DavUser = keyof typeof USERS;

export interface DavResponse {
  status: number;
  headers: Record<string, string>;
  body: string;
}

export interface DavOpts {
  user?: DavUser | null;
  body?: string;
  headers?: Record<string, string>;
}

/** Send a raw WebDAV/CardDAV request. `user: null` sends no auth; default is admin. */
export async function dav(
  request: APIRequestContext,
  method: string,
  path: string,
  opts: DavOpts = {},
): Promise<DavResponse> {
  const user = opts.user === undefined ? "admin" : opts.user;
  const headers: Record<string, string> = { ...(opts.headers ?? {}) };
  if (user !== null) {
    const { email, password } = USERS[user];
    headers["Authorization"] =
      "Basic " + Buffer.from(`${email}:${password}`).toString("base64");
  }
  if (opts.body !== undefined && !Object.keys(headers).some((h) => h.toLowerCase() === "content-type")) {
    headers["Content-Type"] = "application/xml; charset=utf-8";
  }
  const res = await request.fetch(path, {
    method,
    headers,
    data: opts.body,
    maxRedirects: 0,
    failOnStatusCode: false,
  });
  return { status: res.status(), headers: res.headers(), body: await res.text() };
}

/** All <href> values in a multistatus document, prefix-agnostic. */
export function hrefs(xml: string): string[] {
  const out: string[] = [];
  const re = /<(?:[\w.-]+:)?href(?:\s[^>]*)?>([\s\S]*?)<\/(?:[\w.-]+:)?href>/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml))) out.push(decodeXml(m[1].trim()));
  return out;
}

/** The <response> block whose href equals `href`, or undefined. */
export function responseFor(xml: string, href: string): string | undefined {
  const re = /<(?:[\w.-]+:)?response(?:\s[^>]*)?>[\s\S]*?<\/(?:[\w.-]+:)?response>/g;
  let m: RegExpExecArray | null;
  while ((m = re.exec(xml))) {
    const block = m[0];
    if (hrefs(block)[0] === href) return block;
  }
  return undefined;
}

/** Text content of the first element with this local name (any prefix), or undefined. */
export function propText(block: string, localName: string): string | undefined {
  const name = localName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const re = new RegExp(
    `<(?:[\\w.-]+:)?${name}(?:\\s[^>]*)?>([\\s\\S]*?)<\\/(?:[\\w.-]+:)?${name}>`,
  );
  const m = re.exec(block);
  return m ? decodeXml(m[1].trim()) : undefined;
}

/** Throws unless `xmllint --noout -` accepts the document. */
export function assertWellFormedXml(xml: string): void {
  const r = spawnSync("xmllint", ["--noout", "-"], { input: xml, encoding: "utf8" });
  if (r.status !== 0) {
    throw new Error(`XML not well-formed (xmllint exit ${r.status}): ${r.stderr}\n${xml.slice(0, 500)}`);
  }
}

/** Build a vCard with CRLF line endings. */
export function vcard(fields: {
  fn: string;
  email?: string;
  tel?: string;
  uid?: string;
  version?: "3.0" | "4.0";
  extra?: string[];
}): string {
  const lines = ["BEGIN:VCARD", `VERSION:${fields.version ?? "3.0"}`];
  const parts = fields.fn.trim().split(/\s+/);
  const family = parts.length > 1 ? parts[parts.length - 1] : "";
  const given = parts.length > 1 ? parts.slice(0, -1).join(" ") : parts[0];
  lines.push(`N:${family};${given};;;`, `FN:${fields.fn}`);
  if (fields.uid) lines.push(`UID:${fields.uid}`);
  if (fields.email) lines.push(`EMAIL;TYPE=INTERNET:${fields.email}`);
  if (fields.tel) lines.push(`TEL;TYPE=CELL:${fields.tel}`);
  lines.push(...(fields.extra ?? []), "END:VCARD");
  return lines.join("\r\n") + "\r\n";
}

const RUN = `cdv-${Date.now()}`;
/** Per-process-run prefix for naming contacts. */
export function runPrefix(): string {
  return RUN;
}

function decodeXml(s: string): string {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}
