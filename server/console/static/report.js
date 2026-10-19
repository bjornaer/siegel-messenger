// M7 part 5: decrypt a report in the browser with the moderators' key (never uploaded) and show
// it. The Report message is proto/siegel/v1/reports.proto; this reads just the fields it needs.
import { Decrypter } from "/static/age.js";

const box = document.getElementById("contents");
const CATEGORIES = ["", "spam", "harassment", "hate", "child_safety", "non_consensual", "violence", "impersonation", "other"];

function fields(bytes) {
  const out = [];
  let i = 0;
  const varint = () => {
    let v = 0, m = 1, b;
    do { b = bytes[i++]; v += (b & 0x7f) * m; m *= 128; } while (b & 0x80);
    return v;
  };
  while (i < bytes.length) {
    const tag = varint(), field = Math.floor(tag / 8), wire = tag & 7;
    if (wire === 0) out.push([field, varint()]);
    else if (wire === 2) { const n = varint(); out.push([field, bytes.subarray(i, i + n)]); i += n; }
    else if (wire === 1) i += 8;
    else if (wire === 5) i += 4;
    else break;
  }
  return out;
}
const text = (b) => new TextDecoder().decode(b);
const hex = (b) => Array.from(b, (x) => x.toString(16).padStart(2, "0")).join("");

function el(tag, props = {}, ...kids) {
  const e = document.createElement(tag);
  Object.assign(e, props);
  e.append(...kids);
  return e;
}

function message(bytes) {
  const m = {};
  for (const [f, v] of fields(bytes)) {
    if (f === 2) m.sender = hex(v);
    if (f === 3) m.senderName = text(v);
    if (f === 4) m.sentAt = new Date(v);
    if (f === 5) m.text = text(v);
    if (f === 6) m.mime = text(v);
    if (f === 7) m.media = v;
    if (f === 8) m.file = text(v);
  }
  const who = m.senderName || (m.sender ? m.sender.slice(0, 12) : "the reporter");
  const div = el("div", { className: "msg" }, el("div", { className: "muted", textContent: `${who} · ${m.sentAt?.toISOString() ?? ""}` }));
  if (m.text) div.append(el("p", { textContent: m.text }));
  if (m.media && m.media.length) {
    const url = URL.createObjectURL(new Blob([m.media], { type: m.mime || "application/octet-stream" }));
    if (m.mime?.startsWith("image/")) div.append(el("img", { src: url, alt: "attachment" }));
    else if (m.mime?.startsWith("video/")) div.append(el("video", { src: url, controls: true }));
    else if (m.mime?.startsWith("audio/")) div.append(el("audio", { src: url, controls: true }));
    else div.append(el("a", { href: url, download: m.file || "attachment", textContent: `Download ${m.file || "attachment"}` }));
  }
  return div;
}

document.getElementById("key").onchange = async (ev) => {
  const keyFile = await ev.target.files[0].text();
  const key = keyFile.split("\n").map((l) => l.trim()).find((l) => l.startsWith("AGE-SECRET-KEY-"));
  ev.target.value = ""; // the file input forgets it; the key lives only in this function
  if (!key) return (box.textContent = "That file has no age secret key.");
  try {
    const d = new Decrypter();
    d.addIdentity(key);
    const sealed = Uint8Array.from(atob(box.dataset.sealed), (c) => c.charCodeAt(0));
    const plain = await d.decrypt(sealed, "uint8array");
    box.replaceChildren();
    for (const [f, v] of fields(plain)) {
      if (f === 1) box.append(el("p", { textContent: `Reason: ${CATEGORIES[v] ?? v}` }));
      if (f === 2 && v.length) box.append(el("p", { textContent: `Note: ${text(v)}` }));
      if (f === 5 && v.length) box.append(el("p", { textContent: `Reported: ${text(v)}` }));
      if (f === 7 && v.length) box.append(el("p", { textContent: `Group: ${text(v)}` }));
      if (f === 8) box.append(message(v));
    }
  } catch (e) {
    box.textContent = "Couldn't decrypt: " + e.message;
  }
};
