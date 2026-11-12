// FORGED notifications: prayer alerts, 6 PM daily digest, welcome / approved / new-request emails.
// Deployed as the Supabase Edge Function "forged-notify" (JWT verification OFF).
// Database triggers leave a one-time ticket in notify_queue and send only its id; this function
// reads and deletes the ticket with its built-in key, so there is no shared secret to leak.
// Secret to set: SMTP_PASS (Google app password). Optional: SMTP_USER, FROM_NAME, SMTP_HOST, SMTP_PORT.
import { createClient } from "npm:@supabase/supabase-js@2";
import nodemailer from "npm:nodemailer@6.9.16";
import webpush from "npm:web-push@3.6.7";

const SITE = "https://app.menofforged.com";
const LOGO = `${SITE}/logo-720.png`;
const NAVY = "#1B2A4A", GOLD = "#C9A44C", INK = "#1B2A4A", MUTED = "#5B6478", PAPER = "#F7F5F0";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const secretKeys = (() => { try { return JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") || "{}"); } catch { return {}; } })();
const db = createClient(Deno.env.get("SUPABASE_URL")!, secretKeys.default || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
  auth: { persistSession: false },
});

const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
const first = (name: string) => (name || "Brother").trim().split(/\s+/)[0];
const clip = (s: string, n = 180) => (s.length > n ? s.slice(0, n - 1).trimEnd() + "…" : s);

// ---------- branded layout ----------
function layout(o: { preheader: string; heading: string; body: string; button?: { label: string; url: string }; footnote?: string }) {
  const btn = o.button
    ? `<tr><td align="center" style="padding:8px 0 4px"><a href="${o.button.url}" style="display:inline-block;background:${GOLD};color:${NAVY};font-family:Poppins,Arial,sans-serif;font-weight:700;font-size:16px;text-decoration:none;padding:14px 28px;border-radius:10px">${esc(o.button.label)}</a></td></tr>`
    : "";
  return `<!DOCTYPE html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${esc(o.heading)}</title></head>
<body style="margin:0;padding:0;background:${PAPER}">
<span style="display:none;max-height:0;overflow:hidden;opacity:0">${esc(o.preheader)}</span>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:${PAPER}"><tr><td align="center" style="padding:24px 12px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:560px;background:#ffffff;border-radius:14px;overflow:hidden">
<tr><td align="center" style="background:${NAVY};padding:28px 24px 22px"><img src="${LOGO}" width="240" alt="FORGED, Built to Serve" style="display:block;width:240px;max-width:80%;height:auto;border:0"></td></tr>
<tr><td style="height:4px;background:${GOLD};font-size:0;line-height:0">&nbsp;</td></tr>
<tr><td style="padding:30px 30px 8px">
<h1 style="margin:0 0 14px;font-family:Poppins,Arial,sans-serif;font-size:22px;line-height:1.3;color:${INK}">${esc(o.heading)}</h1>
<div style="font-family:Lora,Georgia,serif;font-size:16px;line-height:1.6;color:${INK}">${o.body}</div>
</td></tr>
<tr><td style="padding:6px 30px 26px"><table role="presentation" width="100%">${btn}</table></td></tr>
${o.footnote ? `<tr><td style="padding:0 30px 24px;font-family:Lora,Georgia,serif;font-size:13px;line-height:1.5;color:${MUTED}">${o.footnote}</td></tr>` : ""}
<tr><td style="background:${NAVY};padding:18px 24px;text-align:center;font-family:Poppins,Arial,sans-serif;font-size:12px;letter-spacing:.08em;color:#C9D1E0">
FORGED &middot; MEN'S MINISTRY &middot; 23 CHURCH<br><a href="${SITE}" style="color:${GOLD};text-decoration:none">menofforged.com</a></td></tr>
</table></td></tr></table></body></html>`;
}
const p = (t: string) => `<p style="margin:0 0 14px">${t}</p>`;
const signoff = p(`Forged together,<br><strong>Coach Paul</strong>`);
const prefsNote = `You get these because email updates are on for your FORGED account. Turn them off anytime on the Home screen of the app.`;

// ---------- sending ----------
async function send(list: { to: string; subject: string; html: string; text: string }[]) {
  if (!list.length) return 0;
  const user = Deno.env.get("SMTP_USER") || "paul@menofforged.com", pass = (Deno.env.get("SMTP_PASS") || "").replace(/\s+/g, "");
  if (!pass) throw new Error("Email isn't set up yet: add SMTP_PASS (the Google app password) in Edge Function secrets.");
  const from = `${Deno.env.get("FROM_NAME") || "Coach Paul | FORGED"} <${user}>`;
  const tx = nodemailer.createTransport({
    host: Deno.env.get("SMTP_HOST") || "smtp.gmail.com",
    port: Number(Deno.env.get("SMTP_PORT") || 465),
    secure: (Deno.env.get("SMTP_PORT") || "465") === "465",
    auth: { user, pass },
  });
  let n = 0;
  try {
    for (const m of list) {
      await tx.sendMail({ from, to: m.to, subject: m.subject, text: m.text, html: m.html });
      n++;
    }
  } finally {
    tx.close();
  }
  return n;
}

async function recipients(excludeMemberId?: number) {
  const { data, error } = await db
    .from("members")
    .select("id,name,email")
    .eq("status", "approved")
    .eq("digest_opt_out", false)
    .not("user_id", "is", null)
    .not("email", "is", null);
  if (error) throw error;
  return (data || []).filter((m) => m.id !== excludeMemberId && m.email);
}

// ---------- prayer: right away ----------
async function prayer(messageId: number) {
  const { data: msg } = await db.from("messages").select("*, channels(name,instant)").eq("id", messageId).maybeSingle();
  if (!msg || !msg.channels?.instant) return { sent: 0, reason: "not an instant channel" };
  if (msg.released === false) return { sent: 0, reason: "scheduled, not live yet" };
  const who = msg.member_name || "A brother";
  const quote = esc(msg.body || "(shared a photo)").replace(/\n/g, "<br>");
  const html = layout({
    preheader: `${who} asked the brothers to pray.`,
    heading: `${first(who)} needs prayer`,
    body:
      p(`${esc(who)} just asked the brothers to stand with him:`) +
      `<div style="margin:0 0 16px;padding:14px 16px;border-left:4px solid ${GOLD};background:${PAPER};border-radius:6px;font-style:italic">${quote}</div>` +
      p(`Don't scroll past it. Stop and pray right now, then tell him you did. Nobody stands alone.`),
    button: { label: "Pray with him in the app", url: SITE },
    footnote: prefsNote,
  });
  const text = `${who} asked the brothers to pray:\n\n"${msg.body}"\n\nStop and pray right now, then tell him you did: ${SITE}`;
  const pushed = await pushSafe(await approvedIds(msg.member_id), { title: `🙏 ${first(who)} needs prayer`, body: msg.body || "Shared a photo", url: `/#community-${msg.channel_id}`, tag: `prayer-${msg.id}` });
  const list = (await recipients(msg.member_id)).map((r) => ({ to: r.email, subject: `Prayer request from ${who}`, html, text }));
  return { sent: await send(list), pushed };
}


// ---------- phone alerts (web push) ----------
// Signing keys are created here on first use and kept in push_config (server-only table).
let vapidCache: { pub: string; priv: string } | null = null;
async function vapid() {
  if (vapidCache) return vapidCache;
  let { data: c } = await db.from("push_config").select("vapid_public,vapid_private").eq("id", 1).maybeSingle();
  if (!c) {
    const k = webpush.generateVAPIDKeys();
    await db.from("push_config").upsert({ id: 1, vapid_public: k.publicKey, vapid_private: k.privateKey }, { onConflict: "id", ignoreDuplicates: true });
    ({ data: c } = await db.from("push_config").select("vapid_public,vapid_private").eq("id", 1).maybeSingle());
  }
  if (!c) throw new Error("Could not set up push keys");
  vapidCache = { pub: c.vapid_public, priv: c.vapid_private };
  return vapidCache;
}
async function pushTo(memberIds: number[], note: { title: string; body: string; url?: string; tag?: string }) {
  const ids = [...new Set(memberIds)].filter(Number.isInteger);
  if (!ids.length) return 0;
  const { data: subs, error } = await db.from("push_subscriptions").select("id,endpoint,p256dh,auth,member_id").in("member_id", ids);
  if (error) throw error;
  if (!subs?.length) return 0;
  const k = await vapid();
  const payload = JSON.stringify({ title: note.title, body: clip(note.body, 160), url: note.url || "/", tag: note.tag || "forged" });
  let ok = 0; const dead: number[] = [];
  await Promise.all(subs.map(async (s) => {
    try {
      const d = webpush.generateRequestDetails({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload,
        { TTL: 60 * 60 * 24, urgency: "high", vapidDetails: { subject: "mailto:paul@menofforged.com", publicKey: k.pub, privateKey: k.priv } });
      const r = await fetch(d.endpoint, { method: d.method, headers: d.headers as Record<string, string>, body: d.body });
      if (r.status === 404 || r.status === 410) dead.push(s.id); else if (r.ok) ok++; else console.error("push", r.status, await r.text());
    } catch (e) { console.error("push error", e); }
  }));
  if (dead.length) await db.from("push_subscriptions").delete().in("id", dead);
  return ok;
}
async function pushSafe(memberIds: number[], note: { title: string; body: string; url?: string; tag?: string }) {
  try { return await pushTo(memberIds, note); } catch (e) { console.error("push failed", e); return 0; }
}
async function approvedIds(exclude?: number) {
  const { data } = await db.from("members").select("id").eq("status", "approved").not("user_id", "is", null);
  return (data || []).map((m) => m.id).filter((id) => id !== exclude);
}


// ---------- Brotherhood alerts (phone only) ----------
// A member's new post in a non-prayer chat buzzes the admins (Coach Paul).
async function postAlert(messageId: number) {
  const { data: msg } = await db.from("messages").select("*, channels(name,instant)").eq("id", messageId).maybeSingle();
  if (!msg || msg.parent_id || !msg.channel_id || msg.channels?.instant) return { pushed: 0, reason: "not a new chat post" };
  if (msg.released === false) return { pushed: 0, reason: "scheduled, not live yet" };
  const { data: admins } = await db.from("members").select("id").eq("role", "admin").eq("status", "approved");
  const tagged = new Set((msg.mentions || []) as number[]);
  const ids = (admins || []).map((a) => a.id).filter((id) => id !== msg.member_id && !tagged.has(id));
  const who = msg.member_name || "A brother";
  return { pushed: await pushSafe(ids, { title: `💬 ${first(who)} posted in ${msg.channels?.name || "the Brotherhood"}`, body: msg.body || "Shared a photo", url: `/#community-${msg.channel_id}`, tag: `post-${msg.id}` }) };
}
// A reply buzzes the man who wrote the original post.
async function replyAlert(messageId: number) {
  const { data: msg } = await db.from("messages").select("*").eq("id", messageId).maybeSingle();
  if (!msg || !msg.parent_id) return { pushed: 0, reason: "not a reply" };
  const { data: parent } = await db.from("messages").select("id,member_id").eq("id", msg.parent_id).maybeSingle();
  if (!parent || !parent.member_id || parent.member_id === msg.member_id) return { pushed: 0, reason: "own post or gone" };
  if (((msg.mentions || []) as number[]).includes(parent.member_id)) return { pushed: 0, reason: "covered by the tag alert" };
  const who = msg.member_name || "A brother";
  return { pushed: await pushSafe([parent.member_id], { title: `↩️ ${first(who)} replied to your post`, body: msg.body || "Shared a photo", url: msg.channel_id ? `/#community-${msg.channel_id}` : "/#community", tag: `reply-${msg.id}` }) };
}

// ---------- daily digest ----------
async function buildDigest(since: string) {
  const [{ data: msgs }, { data: teach }, { data: evNew }, { data: upcoming }] = await Promise.all([
    db.from("messages").select("member_name,body,created_at,channel_id,teaching_id,channels(name,instant),teachings(title)").gt("created_at", since).eq("released", true).order("created_at"),
    db.from("teachings").select("title,description,kind").gt("created_at", since).order("created_at"),
    db.from("events").select("title,event_date,start_time,location").gt("created_at", since).order("event_date"),
    db.from("events").select("title,event_date,start_time,location")
      .gte("event_date", new Date().toISOString().slice(0, 10))
      .lte("event_date", new Date(Date.now() + 7 * 864e5).toISOString().slice(0, 10)).order("event_date"),
  ]);
  const chat = (msgs || []).filter((m: any) => m.channel_id && !m.channels?.instant);
  const prayerCount = (msgs || []).filter((m: any) => m.channel_id && m.channels?.instant).length;
  const talk = (msgs || []).filter((m: any) => m.teaching_id);
  const newCount = chat.length + talk.length + (teach || []).length + (evNew || []).length + prayerCount;
  if (!newCount) return null;

  const h2 = (t: string) => `<h2 style="margin:22px 0 8px;font-family:Poppins,Arial,sans-serif;font-size:13px;letter-spacing:.16em;text-transform:uppercase;color:#8A6A1F">${t}</h2>`;
  const li = (t: string) => `<li style="margin:0 0 8px">${t}</li>`;
  const ul = (items: string[]) => `<ul style="margin:0 0 6px;padding-left:20px">${items.join("")}</ul>`;
  const when = (e: any) => {
    const d = new Date(e.event_date + "T12:00:00");
    const day = d.toLocaleDateString("en-US", { weekday: "short", month: "short", day: "numeric" });
    let t = "";
    if (e.start_time) { const [H, M] = e.start_time.split(":").map(Number); t = ` at ${((H + 11) % 12) + 1}:${String(M).padStart(2, "0")} ${H < 12 ? "AM" : "PM"}`; }
    return `${day}${t}${e.location ? `, ${esc(e.location)}` : ""}`;
  };
  let body = p(`Here's what God has been doing in the brotherhood today.`);
  const sections: string[] = [];
  if (chat.length) {
    const byCh: Record<string, any[]> = {};
    chat.forEach((m: any) => (byCh[m.channels?.name || "Community"] ||= []).push(m));
    body += h2("In the room");
    body += ul(Object.entries(byCh).map(([ch, arr]) =>
      li(`<strong>${esc(ch)}</strong>: ${arr.length} new ${arr.length === 1 ? "post" : "posts"}. Latest from ${esc(arr.at(-1).member_name)}: "${esc(clip(arr.at(-1).body || "shared a photo", 140))}"`)));
    sections.push(`${chat.length} new posts`);
  }
  if (prayerCount) { body += h2("Prayer"); body += p(`${prayerCount} prayer ${prayerCount === 1 ? "request" : "requests"} today. If you haven't yet, go stand with your brothers.`); }
  if (talk.length) {
    const byT: Record<string, number> = {};
    talk.forEach((m: any) => (byT[m.teachings?.title || "a teaching"] = (byT[m.teachings?.title || "a teaching"] || 0) + 1));
    body += h2("Teaching discussions");
    body += ul(Object.entries(byT).map(([t, n]) => li(`${n} new ${n === 1 ? "comment" : "comments"} on <strong>${esc(t)}</strong>`)));
  }
  if ((teach || []).length) {
    const k: Record<string, string> = { video: "Video", audio: "Audio", pdf: "Worksheet" };
    body += h2("New in Teachings");
    body += ul(teach!.map((t: any) => li(`<strong>${esc(t.title)}</strong> (${k[t.kind] || "Teaching"})${t.description ? `: ${esc(clip(t.description, 120))}` : ""}`)));
    sections.push(`${teach!.length} new teaching${teach!.length === 1 ? "" : "s"}`);
  }
  if ((evNew || []).length) { body += h2("New events"); body += ul(evNew!.map((e: any) => li(`<strong>${esc(e.title)}</strong>: ${when(e)}`))); }
  const newKeys = new Set((evNew || []).map((e: any) => e.title + e.event_date + e.start_time));
  const soon = (upcoming || []).filter((e: any) => !newKeys.has(e.title + e.event_date + e.start_time));
  if (soon.length) { body += h2("Coming up this week"); body += ul(soon.map((e: any) => li(`<strong>${esc(e.title)}</strong>: ${when(e)}`))); }
  body += p(`Show up. Speak up. Sharpen somebody.`) + signoff;

  const subject = `Today in FORGED: ${sections[0] || `${newCount} new`}${sections[1] ? ` and ${sections[1]}` : ""}`;
  const html = layout({ preheader: "What happened in the brotherhood today.", heading: "Today in FORGED", body, button: { label: "Open FORGED", url: SITE }, footnote: prefsNote });
  const text = `Today in FORGED\n\n${chat.length} new posts, ${prayerCount} prayer requests, ${talk.length} teaching comments, ${(teach || []).length} new teachings, ${(evNew || []).length} new events.\n\nOpen FORGED: ${SITE}`;
  return { subject, html, text };
}

async function digestTick(force = false) {
  const now = new Date();
  const hour = Number(new Intl.DateTimeFormat("en-US", { timeZone: "America/Denver", hour: "numeric", hourCycle: "h23" }).format(now));
  const today = new Intl.DateTimeFormat("en-CA", { timeZone: "America/Denver" }).format(now);
  const { data: st } = await db.from("notify_state").select("*").eq("id", 1).maybeSingle();
  if (!force && (hour !== 18 || st?.last_digest_day === today)) return { sent: 0, reason: "not digest time" };
  const since = st?.last_digest_at || new Date(Date.now() - 864e5).toISOString();
  const d = await buildDigest(since);
  await db.from("notify_state").upsert({ id: 1, last_digest_at: now.toISOString(), last_digest_day: today });
  if (!d) return { sent: 0, reason: "Nothing new today, so no digest went out." };
  const list = (await recipients()).map((r) => ({ to: r.email, ...d }));
  return { sent: await send(list) };
}

async function digestTest(adminEmail: string) {
  const d = await buildDigest(new Date(Date.now() - 864e5).toISOString());
  if (!d) return { sent: 0, reason: "Nothing new in the last 24 hours, so there's nothing to put in a digest yet." };
  return { sent: await send([{ to: adminEmail, ...d, subject: `[Test] ${d.subject}` }]) };
}

// ---------- @mentions ----------
async function mention(messageId: number) {
  const { data: msg } = await db.from("messages").select("*, channels(name,instant), teachings(title)").eq("id", messageId).maybeSingle();
  if (!msg || !(msg.mentions || []).length) return { sent: 0 };
  if (msg.released === false) return { sent: 0, reason: "scheduled, not live yet" };
  if (!msg.parent_id && msg.channels?.instant) return { sent: 0, reason: "covered by the prayer alert" };
  const tagger = msg.member_name || "A brother";
  const pushed = await pushSafe((msg.mentions as number[]).filter((id) => id !== msg.member_id), { title: `${first(tagger)} tagged you`, body: msg.body || "Shared a photo", url: msg.channel_id ? `/#community-${msg.channel_id}` : "/#teachings", tag: `mention-${msg.id}` });
  const { data: ms, error } = await db.from("members").select("id,name,email").in("id", msg.mentions)
    .eq("status", "approved").eq("digest_opt_out", false).not("user_id", "is", null).not("email", "is", null);
  if (error) throw error;
  const who = msg.member_name || "A brother";
  const where = msg.channels?.name || msg.teachings?.title || "FORGED";
  const quote = esc(clip(msg.body || "(shared a photo)", 600)).replace(/\n/g, "<br>");
  const list = (ms || []).filter((m) => m.id !== msg.member_id).map((m) => ({
    to: m.email,
    subject: `${who} tagged you in ${where}`,
    html: layout({
      preheader: `${who} mentioned you in FORGED.`,
      heading: `${first(who)} tagged you, ${first(m.name)}`,
      body:
        p(`${esc(who)} mentioned you ${msg.parent_id ? "in a reply " : ""}in <strong>${esc(where)}</strong>:`) +
        `<div style="margin:0 0 16px;padding:14px 16px;border-left:4px solid ${GOLD};background:${PAPER};border-radius:6px">${quote}</div>` +
        p(`Go see what he said, and answer him. That's how iron sharpens iron.`),
      button: { label: "See the post", url: SITE },
      footnote: prefsNote,
    }),
    text: `${who} mentioned you in ${where}:\n\n"${msg.body || ""}"\n\nSee the post: ${SITE}`,
  }));
  return { sent: await send(list), pushed };
}

// ---------- member emails ----------
async function memberEvent(kind: string, memberId: number) {
  const { data: m } = await db.from("members").select("*").eq("id", memberId).maybeSingle();
  if (!m) return { sent: 0 };
  if (kind === "member_added" && m.email) {
    const html = layout({
      preheader: "Coach Paul added you to the FORGED app.",
      heading: `You're in, ${first(m.name)}. Welcome to FORGED.`,
      body:
        p(`Coach Paul added you to the FORGED app. It's where we stay in the Word, show up on Tuesdays, and keep each other honest between meetings.`) +
        p(`<strong>Getting in takes one minute:</strong>`) +
        `<ol style="margin:0 0 14px;padding-left:20px"><li>Go to <a href="${SITE}" style="color:#8A6A1F">app.menofforged.com</a></li><li>Tap <strong>Request access</strong></li><li>Use this email (${esc(m.email)}) and create a password</li></ol>` +
        p(`You'll go straight in. No waiting.`) + signoff,
      button: { label: "Set up my account", url: SITE },
    });
    return { sent: await send([{ to: m.email, subject: `You're in, ${first(m.name)}. Welcome to FORGED.`, html, text: `Coach Paul added you to the FORGED app. Go to ${SITE}, tap Request access, and use ${m.email} to create your password. You'll go straight in.` }]) };
  }
  if (kind === "approved" && m.email) {
    const html = layout({
      preheader: "Coach Paul approved your request.",
      heading: `Welcome to the brotherhood, ${first(m.name)}.`,
      body:
        p(`Coach Paul approved your request. The room is open.`) +
        p(`Inside you'll find this week's teaching and worksheet, our Tuesday gatherings, and the Brotherhood and Prayer chats. Don't just lurk. Introduce yourself and tell the men one thing God is working on in you.`) + signoff,
      button: { label: "Open FORGED", url: SITE },
    });
    return { sent: await send([{ to: m.email, subject: "You're in. Welcome to FORGED.", html, text: `Coach Paul approved your request. Sign in at ${SITE}.` }]) };
  }
  if (kind === "new_request") {
    const { data: admins } = await db.from("members").select("id,email").eq("role", "admin").eq("status", "approved").not("email", "is", null);
    await pushSafe((admins || []).map((a) => a.id), { title: "New FORGED request", body: `${m.name} asked to join.`, url: "/#members", tag: `req-${m.id}` });
    const html = layout({
      preheader: `${m.name} asked to join FORGED.`,
      heading: `New request: ${m.name}`,
      body: p(`<strong>${esc(m.name)}</strong> (${esc(m.email)}) asked to join FORGED.`) + (m.note ? `<div style="margin:0 0 16px;padding:12px 16px;border-left:4px solid ${GOLD};background:${PAPER};border-radius:6px">${esc(m.note)}</div>` : ""),
      button: { label: "Review requests", url: SITE },
    });
    return { sent: await send((admins || []).map((a) => ({ to: a.email, subject: `New FORGED request: ${m.name}`, html, text: `${m.name} (${m.email}) asked to join. Review at ${SITE}` }))) };
  }
  return { sent: 0 };
}

// ---------- entry ----------
Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  const reply = (b: unknown, s = 200) => new Response(JSON.stringify(b), { status: s, headers: { ...cors, "Content-Type": "application/json" } });
  try {
    const body = await req.json().catch(() => ({}));
    let job: { kind: string; payload: any } | null = null;
    if (typeof body.ticket === "string" && /^[0-9a-f-]{36}$/i.test(body.ticket)) {
      const { data: t } = await db.from("notify_queue").delete().eq("token", body.ticket).select("kind,payload").maybeSingle();
      if (t) job = { kind: t.kind, payload: t.payload || {} };
    }
    if (!job && body.type === "vapid_public") return reply({ key: (await vapid()).pub });
    if (!job && body.type === "push_test") {
      const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: u } = jwt ? await db.auth.getUser(jwt) : { data: null };
      const { data: me } = u?.user ? await db.from("members").select("id,name,status").eq("user_id", u.user.id).maybeSingle() : { data: null };
      if (!me || me.status !== "approved") return reply({ error: "Not allowed" }, 403);
      return reply({ pushed: await pushTo([me.id], { title: "FORGED alerts are on 🔥", body: `You're set, ${first(me.name)}. Prayer requests and @tags will show up right here.`, url: "/", tag: "test" }) });
    }
    if (!job) {
      // Otherwise only an approved admin, signed in to the app, may trigger a test digest.
      const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: u } = jwt ? await db.auth.getUser(jwt) : { data: null };
      const { data: me } = u?.user ? await db.from("members").select("email,role,status").eq("user_id", u.user.id).maybeSingle() : { data: null };
      if (!me || me.role !== "admin" || me.status !== "approved" || body.type !== "digest_test") return reply({ error: "Not allowed" }, 403);
      return reply(await digestTest(me.email));
    }
    const pl = job.payload;
    switch (job.kind) {
      case "prayer": return reply(await prayer(pl.message_id));
      case "mention": return reply(await mention(pl.message_id));
      case "post": return reply(await postAlert(pl.message_id));
      case "reply": return reply(await replyAlert(pl.message_id));
      case "digest_tick": return reply(await digestTick(false));
      case "digest_force": return reply(await digestTick(true));
      case "member_added":
      case "approved":
      case "new_request": return reply(await memberEvent(job.kind, pl.member_id));
      default: return reply({ error: "unknown type" }, 400);
    }
  } catch (e) {
    console.error(e);
    return reply({ error: String((e as Error)?.message || e) }, 500);
  }
});
