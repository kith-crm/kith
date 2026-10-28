import { type APIRequestContext } from "@playwright/test";
import { createHash } from "node:crypto";
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

const NAME = String.raw`(?:[\w.-]+:)?`;

/**
 * Elements with the given local name (any prefix), in document order.
 * Self-closed elements (`<x/>`, `<x />`, with attributes) yield an empty
 * inner string and never match across to a later closing tag.
 */
function elements(xml: string, localName: string): { start: number; end: number; inner: string }[] {
  const name = localName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const open = new RegExp(`<${NAME}${name}(?:\\s[^>]*?)?(\\/?)>`, "g");
  const close = new RegExp(`<\\/${NAME}${name}\\s*>`, "g");
  const out: { start: number; end: number; inner: string }[] = [];
  let m: RegExpExecArray | null;
  while ((m = open.exec(xml))) {
    const innerStart = m.index + m[0].length;
    if (m[1] === "/") {
      out.push({ start: m.index, end: innerStart, inner: "" });
      continue;
    }
    close.lastIndex = innerStart;
    const c = close.exec(xml);
    if (!c) break;
    out.push({ start: m.index, end: c.index + c[0].length, inner: xml.slice(innerStart, c.index) });
    open.lastIndex = c.index + c[0].length;
  }
  return out;
}

/** All <href> values in a multistatus document, prefix-agnostic. */
export function hrefs(xml: string): string[] {
  return elements(xml, "href").map((e) => decodeXml(e.inner.trim()));
}

/** The <response> block whose first href equals `href`, or undefined. */
export function responseFor(xml: string, href: string): string | undefined {
  for (const e of elements(xml, "response")) {
    const block = xml.slice(e.start, e.end);
    if (hrefs(block)[0] === href) return block;
  }
  return undefined;
}

/** Text content of the first element with this local name (any prefix); "" if self-closed, undefined if absent. */
export function propText(block: string, localName: string): string | undefined {
  const e = elements(block, localName)[0];
  return e ? decodeXml(e.inner.trim()) : undefined;
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

export function decodeXml(s: string): string {
  return s
    .replace(/&#x([0-9a-fA-F]+);/g, (_, h) => String.fromCodePoint(parseInt(h, 16)))
    .replace(/&#(\d+);/g, (_, d) => String.fromCodePoint(parseInt(d, 10)))
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

/** Discover a stored resource by a unique name fragment; IDs never determine hrefs. */
export async function discoverHref(request: APIRequestContext, name: string): Promise<string> {
  const book = "/dav/addressbooks/default/";
  const text = name.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
  // Query the unique FN fragment instead of fetching every member separately.
  // This stays bounded in HTTP requests as repeated isolated runs add fixtures.
  const result = await dav(request, "REPORT", book, {
    body: `<card:addressbook-query xmlns:d="DAV:" xmlns:card="urn:ietf:params:xml:ns:carddav"><d:prop><d:getetag/></d:prop><card:filter><card:prop-filter name="FN"><card:text-match match-type="contains">${text}</card:text-match></card:prop-filter></card:filter></card:addressbook-query>`,
  });
  if (result.status !== 207) throw new Error(`FN query: ${result.status}: ${result.body.slice(0, 300)}`);
  const matches = hrefs(result.body).filter(href => href.endsWith(".vcf"));
  if (matches.length !== 1) throw new Error(`Expected one DAV resource for ${name}, found ${matches.length}`);
  return matches[0];
}

/** Stable UUID for named fixtures; names stay readable without becoming DAV identities. */
export function testUid(seed: string): string {
  const hex = createHash("sha256").update(seed).digest("hex");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-4${hex.slice(13, 16)}-8${hex.slice(17, 20)}-${hex.slice(20, 32)}`;
}
export function wireUid(uuid: string): string {
  return "urn:uuid:" + uuid.replace(/^urn:uuid:/i, "").toLowerCase();
}
export function photoBytes(card: string): Buffer {
  const unfolded = card.replace(/\r\n[ \t]/g, "");
  const photo = unfolded.match(/^PHOTO(?:;[^:\r\n]*)?:(?:data:image\/[^;]+;base64,)?([^\r\n]+)\r?$/m);
  if (!photo) throw new Error("Missing PHOTO");
  return Buffer.from(photo[1], "base64");
}
