"""Build the review gallery and standalone HTML email designs. No emails are sent."""

import base64
import html
import json
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parent
LOGO = "data:image/png;base64," + base64.b64encode((ROOT / "logo.png").read_bytes()).decode()

# sRGB equivalents of the light theme tokens in assets/css/app.css.
# The logo retains its original #FD4F00; CTAs use --color-accent.
BRAND = dict(accent="#d25900", accent_subtle="#fef8e5", surface="#fbfaf7",
             sunken="#f6f4f0", card="#ffffff", text="#1c1917",
             secondary="#57534d", tertiary="#79716b", border="#d6d3d0",
             subtle_border="#e5e3e1")


def reminder(id, name, subject, event, occurrence_date, relative, saved_note, source,
             date_label="Due date"):
    day = date.fromisoformat(occurrence_date)
    formatted = f"{day.day} {day:%B %Y}"
    return item(id, name, "Reminders", subject, "Sam Rivera", "",
                "View Sam’s profile", "/contacts/42", "",
                eyebrow="REMINDER", preheader=f"Sam Rivera · {event} · {formatted} · {relative}.",
                contact_name="Sam Rivera", initials="SR", event=event,
                occurrence_date=occurrence_date, date_display=formatted,
                weekday=day.strftime("%A"), relative=relative, date_label=date_label,
                saved_note=saved_note,
                source="lib/kith/workers/reminder_email_worker.ex · " + source,
                fields=["contact name", "occurrence_date", "kind", "days_before",
                        "description (optional)", "contact_id"], expiry="No expiry")


def item(id, name, group, subject, title, body, action, path, note, **extra):
    return dict(id=id, name=name, group=group, subject=subject, title=title,
                body=body, action=action, url="https://kith.example" + path,
                note=note, status="Active flow", **extra)


EMAILS = [
    item("confirmation", "Confirm account", "Account", "Confirm your Kith account",
         "Confirm your email address",
         "Thanks for creating your Kith account. Confirm your email address to start keeping the people who matter close.",
         "Confirm email address", "/users/confirm/sample-token",
         "This link is valid for 7 days. If you didn’t create a Kith account, you can ignore this email.",
         eyebrow="EMAIL CONFIRMATION", preheader="Confirm your email address to get started with Kith.",
         source="lib/kith/accounts/user_notifier.ex · deliver_confirmation_instructions/2",
         fields=["user.email", "confirmation_url"], expiry="7 days · UserToken"),
    item("password-reset", "Reset password", "Account", "Reset your Kith password",
         "Reset your password",
         "We received a request to reset the password for your Kith account. Choose a new password using the button below.",
         "Reset password", "/users/reset-password/sample-token",
         "This link expires in 1 hour. If you didn’t request a reset, ignore this email. Your password will stay the same.",
         eyebrow="ACCOUNT SECURITY", preheader="Reset your Kith password. This link expires in 1 hour.",
         source="lib/kith/accounts/user_notifier.ex · deliver_reset_password_instructions/2",
         fields=["user.email", "reset_url"], expiry="1 hour · UserToken"),
    item("email-change", "Change email", "Account", "Update email instructions",
         "Confirm your\nnew email address.",
         "You asked to use this email address for your Kith account. Confirm the change below to finish updating your account.",
         "Confirm new email", "/users/settings/confirm-email/sample-token",
         "This link is valid for 7 days. If you didn’t request this change, ignore this email. Your account email will stay the same.",
         eyebrow="ACCOUNT SECURITY", preheader="One more step to update your Kith email address.",
         source="lib/kith/accounts/user_notifier.ex · deliver_update_email_instructions/2",
         fields=["user.email (new address)", "change_email_url"], expiry="7 days · UserToken"),
    item("invitation", "Account invitation", "Account", "You've been invited to join The Morgan Family on Kith",
         "You’re invited to join",
         "<strong>Alex Morgan</strong> has invited you to join <strong>The Morgan Family</strong> on Kith. Keep important details and shared connections together in one thoughtful space.",
         "Accept invitation", "/invitations/sample-token",
         "This invitation expires in 7 days. If you weren’t expecting it, you can ignore this email.",
         eyebrow="YOU’RE INVITED", preheader="Alex Morgan invited you to The Morgan Family as an editor.",
         panel=("YOUR INVITATION", "The Morgan Family", "Invited by Alex Morgan · Role: Editor"),
         source="lib/kith/accounts/user_notifier.ex · deliver_invitation/2",
         fields=["account_name", "invited_by_name", "role", "invitation_url"], expiry="7 days · invitation"),
    reminder("birthday-today", "Birthday · today", "Sam Rivera's birthday is today",
             "Birthday", "2026-10-28", "Today", "Call after work.", "birthday / on_day", "Birthday date"),
    reminder("birthday-upcoming", "Birthday · upcoming", "Sam Rivera's birthday is in 7 days",
             "Birthday", "2026-11-04", "In 7 days", "Find a book they’ll love.", "birthday / advance", "Birthday date"),
    reminder("first-met", "First-met anniversary", "Anniversary of meeting Sam Rivera",
             "First-met anniversary", "2026-10-28", "Today", "We met at Maya’s dinner.",
             "first_met / all kinds", "Anniversary date"),
    reminder("stay-in-touch", "Stay in touch", "Time to reach out to Sam Rivera",
             "Stay in touch", "2026-10-28", "Today", "Ask how the new job is going.",
             "stay_in_touch / all kinds", "Reach out by"),
    reminder("reminder-upcoming", "Reminder · upcoming", "Reminder in 3 days: Catch up over coffee",
             "Catch up over coffee", "2026-10-31", "In 3 days", "Try the new place on Oak Street.",
             "one_time / advance"),
    reminder("reminder-due", "Reminder · due", "Reminder: Catch up over coffee",
             "Catch up over coffee", "2026-10-28", "Today", "Try the new place on Oak Street.",
             "fallback; also Kith.Emails.reminder_notification/2"),
    item("welcome", "Welcome to Kith", "Library", "Welcome to Kith",
         "For the people\nwho matter.",
         "Welcome to Kith. A thoughtful place to remember the little things, make time for a conversation, and nurture the connections in your life.",
         "Add your first contact", "/contacts/new",
         "You’re receiving this because you created a Kith account.",
         eyebrow="WELCOME TO KITH", preheader="Start with one person. Build a habit of staying close.",
         source="lib/kith/emails.ex · welcome/1 · no delivery caller found",
         fields=["user.email", "instance base URL"], expiry="No expiry", steps=True),
    item("export", "Data export ready", "Library", "Your data export is ready",
         "Your export is ready",
         "Your Kith data export is ready to download. Keep a copy for your records or take it with you whenever you need.",
         "Download export", "/export/sample-download-token",
         "This download is available for 24 hours. After that, request a new export from your account settings.",
         eyebrow="DATA EXPORT", preheader="Your Kith data export is ready. Download your copy.",
         panel=("YOUR EXPORT", "Kith account data", "JSON format · Keep your download somewhere safe"),
         source="lib/kith/emails.ex · data_export_ready/2 · export worker only logs completion",
         fields=["user.email", "signed_download_url (integration pending)"], expiry="24 hours proposed · worker cache lifetime"),
]

for email in EMAILS:
    if email["group"] == "Library":
        email["status"] = "Builder only"


def render_email(e):
    esc = html.escape
    b = BRAND
    is_reminder = e["group"] == "Reminders"
    panel = ""
    if "panel" in e:
        label, title, detail = map(esc, e["panel"])
        panel = f'''<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="margin:24px 0 0;background:{b['sunken']};border:1px solid {b['subtle_border']};border-radius:6px;"><tr><td style="padding:20px;"><p style="margin:0 0 9px;color:{b['tertiary']};font-size:11px;font-weight:700;letter-spacing:1px;">{label}</p><p style="margin:0;color:{b['text']};font-size:19px;font-weight:600;line-height:1.4;">{title}</p><p style="margin:9px 0 0;color:{b['secondary']};font-size:13px;line-height:1.7;">{detail}</p></td></tr></table>'''
    if e.get("steps"):
        panel = f'<p style="margin:28px 0 14px;color:{b["tertiary"]};font-size:11px;letter-spacing:1px;font-weight:700;">GETTING STARTED</p>'
        for num, title, desc in [("01", "Add a contact", "Save the details you want to remember."), ("02", "Set a reminder", "Choose when to get back in touch."), ("03", "Save a note", "Keep track of your conversations.")]:
            panel += f'<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="border-top:1px solid {b["subtle_border"]};"><tr><td width="34" valign="top" style="padding:16px 0;color:{b["accent"]};font-size:11px;">{num}</td><td style="padding:14px 0;"><p style="margin:0;color:{b["text"]};font-size:14px;font-weight:600;">{title}</p><p style="margin:5px 0 0;color:{b["secondary"]};font-size:13px;line-height:1.6;">{desc}</p></td></tr></table>'
    if is_reminder:
        saved_note = ""
        if e.get("saved_note"):
            saved_note = f'''<div style="margin-top:24px;"><p style="margin:0 0 7px;font-size:11px;color:{b['tertiary']};font-weight:600;">YOUR NOTE</p><p style="margin:0;font-size:14px;color:{b['secondary']};line-height:1.7;">{esc(e['saved_note'])}</p></div>'''
        content = f'''<p style="margin:0 0 20px;color:{b['tertiary']};font-size:11px;font-weight:600;letter-spacing:1px;">REMINDER</p>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0"><tr><td width="62" valign="top"><table role="presentation" cellspacing="0" cellpadding="0"><tr><td width="46" height="46" align="center" style="background:{b['accent_subtle']};border:1px solid {b['subtle_border']};border-radius:23px;color:{b['accent']};font-size:14px;font-weight:700;">{esc(e['initials'])}</td></tr></table></td><td><h1 style="margin:0;color:{b['text']};font-size:28px;line-height:1.25;font-weight:600;letter-spacing:-0.8px;overflow-wrap:anywhere;">{esc(e['contact_name'])}</h1><p style="margin:7px 0 0;color:{b['secondary']};font-size:16px;line-height:1.5;">{esc(e['event'])}</p></td></tr></table>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="margin-top:24px;background:{b['accent_subtle']};border-radius:6px;"><tr><td style="padding:20px;border-left:3px solid {b['accent']};"><p style="margin:0 0 10px;color:{b['secondary']};font-size:11px;font-weight:600;">{esc(e['date_label']).upper()}</p><p style="margin:0;color:{b['text']};font-size:23px;font-weight:600;line-height:1.35;">{esc(e['date_display'])}</p><p style="margin:8px 0 0;color:{b['secondary']};font-size:13px;line-height:1.6;">{esc(e['weekday'])} &nbsp;·&nbsp; <strong>{esc(e['relative'])}</strong></p></td></tr></table>
{saved_note}'''
    else:
        title = esc(e["title"]).replace('\n', '<br>')
        content = f'''<p style="margin:0 0 16px;color:{b['accent']};font-size:11px;font-weight:600;letter-spacing:1px;line-height:1.5;">{esc(e['eyebrow'])}</p><h1 style="margin:0 0 18px;font-size:28px;font-weight:600;line-height:1.3;letter-spacing:-0.8px;color:{b['text']};">{title}</h1><p style="margin:0;color:{b['secondary']};font-size:14px;line-height:1.8;">{e['body']}</p>{panel}'''
    footer = ("You received this invitation from Alex Morgan via Kith." if e["id"] == "invitation" else
              "Sent by Kith for your account." if not is_reminder else "You set this reminder in Kith.")
    fallback = ''
    if e["group"] == "Account" or e["id"] == "export":
        fallback = f'<p style="margin:20px 0 0;font-size:11px;line-height:1.7;color:{b["tertiary"]};">Button not working? Copy this link into your browser:<br><a href="{esc(e["url"])}" style="color:{b["secondary"]};text-decoration:underline;word-break:break-all;">{esc(e["url"])}</a></p>'
    note = f'<p style="margin:0;color:{b["tertiary"]};font-size:12px;line-height:1.8;">{esc(e["note"])}</p>' if e["note"] else ''
    return f'''<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>{esc(e['subject'])}</title></head>
<body style="margin:0;padding:0;background:{b['surface']};color:{b['text']};font-family:Arial,Helvetica,sans-serif;">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;mso-hide:all;">{esc(e['preheader'])}</div>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="background:{b['surface']};"><tr><td align="center" style="padding:28px 12px;">
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:560px;width:100%;background:{b['card']};border:1px solid {b['border']};border-radius:8px;">
<tr><td style="padding:24px 24px 22px;border-bottom:1px solid {b['subtle_border']};">
<table role="presentation" cellspacing="0" cellpadding="0"><tr><td width="53"><img src="{LOGO}" alt="Kith logo" width="47" height="32" style="display:block;border:0;"></td><td style="font-size:27px;letter-spacing:-1.2px;font-weight:700;color:{b['text']};">Kith</td></tr></table>
</td></tr><tr><td style="padding:28px 24px 26px;">
{content}
<table role="presentation" cellspacing="0" cellpadding="0" style="margin:26px 0 0;"><tr><td bgcolor="{b['accent']}" style="border-radius:6px;text-align:center;"><a data-cta="primary" href="{esc(e['url'])}" style="display:inline-block;padding:14px 20px;border:1px solid {b['accent']};border-radius:6px;font-size:13px;line-height:18px;font-weight:600;color:#ffffff;text-decoration:none;">{esc(e['action'])}</a></td></tr></table>
{'<div style="margin-top:20px;">' + note + fallback + '</div>' if note or fallback else ''}
</td></tr></table>
<table role="presentation" width="100%" cellspacing="0" cellpadding="0" style="max-width:560px;"><tr><td style="padding:18px 18px 0;text-align:center;"><p style="margin:0;font-size:11px;line-height:1.8;color:{b['tertiary']};">{footer}</p></td></tr></table>
</td></tr></table></body></html>'''


for e in EMAILS:
    e["html"] = render_email(e)
    (ROOT / f"{e['id']}.html").write_text(e["html"])

inventory = {"scope": "Source-code inventory, not historical inbox messages. Design mockups only; delivery code is unchanged.",
             "brand": {"source": "assets/css/app.css · light theme", "colors": BRAND},
             "active_families": 5, "active_variants": 10, "builder_only": 2,
             "notes": [
                 "Actual senders are UserNotifier and ReminderEmailWorker; Kith.Emails has separate builders with no delivery callers found.",
                 "Confirmation builder says 24 hours; actual UserToken validity is 7 days. Designs use 7 days.",
                 "Export builder says 48 hours; ExportWorker caches for 24 hours and does not deliver mail. Design proposes 24 hours pending download integration.",
                 "Reminder action buttons are proposed additions; the worker currently sends plain text only. Use the instance base URL and contact_id when integrating.",
                 "Reminder dates come from instance.occurrence_date, not scheduled_for (advance reminders fire earlier). Derive relative labels against the account-local date; show Overdue where appropriate. Dates shown here assume a sample send date of 28 October 2026. Format dates using the recipient locale. First-met Today is only an on-day sample, not the copy for advance notices.",
                 "Kith.Emails.invitation/2 and reminder_notification/2 map to the invitation and due-reminder designs; email_verification/2 and password_reset/2 map to account confirmation and reset.",
                 "All names, addresses, dates, and URLs are fictional sample data. Role and descriptions must be HTML-escaped during integration.",
                 "Standalone designs embed the existing logo as PNG data for portable review. For delivery, use a CID PNG attachment or an absolute HTTPS asset URL; do not ship data URI images to email clients.",
                 "No email-client compatibility certification performed. Test Outlook, Gmail, Apple Mail, images disabled and dark mode before rollout. Preserve plain-text alternatives, subjects, expiry checks and delivery behavior."
             ], "templates": [{k: v for k, v in e.items() if k != "html"} for e in EMAILS]}
(ROOT / "inventory.json").write_text(json.dumps(inventory, indent=2, ensure_ascii=False) + '\n')

GALLERY = '''<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Kith · Email design collection</title><style>
*{box-sizing:border-box}body{margin:0;color:var(--foreground,#1c1917);font-family:Arial,Helvetica,sans-serif;background:transparent}button,select{font:inherit}button{cursor:pointer}h2{margin:8px 0 12px;font-size:29px;letter-spacing:-1px;font-weight:500}p{line-height:1.7}.intro{font-size:13px;color:var(--muted-foreground,#777);margin:0 0 20px;max-width:620px}.kicker{font-size:10px;letter-spacing:2px;color:#d25900;font-weight:700}.stats{display:flex;gap:18px;padding:0 0 20px;font-size:11px;color:var(--muted-foreground,#777)}.stats b{color:var(--foreground,#1c1917);font-size:16px;margin-right:4px}.toolbar{display:flex;gap:6px;flex-wrap:wrap;margin-bottom:12px}.tab,.view{border:1px solid var(--border,#ddd);background:transparent;color:var(--muted-foreground,#777);padding:9px 12px;border-radius:5px;font-size:11px}.tab[aria-pressed=true]{background:var(--foreground,#1c1917);color:var(--background,#fff);border-color:var(--foreground,#1c1917)}.count{opacity:.6;margin-left:6px}.navigator{display:flex;gap:8px;align-items:center;margin-bottom:16px}select{flex:1;width:100px;padding:12px;border:1px solid var(--border,#ddd);border-radius:5px;background:var(--card,#fff);color:var(--foreground,#1c1917);font-size:12px}.view[aria-pressed=true]{border-color:#d25900;color:#d25900;background:#d2590010}.paper{padding:20px;background:#f6f4f0;border-radius:8px}.envelope{padding:0 0 16px;color:#57534d;font-size:11px}.envelope strong{color:#1c1917}.subject{font-size:13px;font-weight:600;color:#1c1917;margin:6px 0}.preview-wrap{max-width:600px;margin:auto;transition:max-width .2s}.preview-wrap.mobile{max-width:360px}iframe{display:block;border:0;width:100%;height:800px;background:#fbfaf7;border-radius:4px}.bottom{display:flex;align-items:center;justify-content:space-between;gap:12px;margin-top:14px;font-size:11px}.badge{background:#79716b18;color:#79716b;padding:5px 8px;border-radius:4px}.badge.library{background:#d2590018;color:#d25900}.pagination{display:flex;gap:8px}.pagination button{border:1px solid var(--border,#ddd);border-radius:4px;background:transparent;color:var(--foreground,#1c1917);padding:8px 12px}.detail{font-size:11px;color:var(--muted-foreground,#777);line-height:1.8;margin-top:16px}.detail code{font-size:10px;overflow-wrap:anywhere}details{margin-top:20px;border-top:1px solid var(--border,#ddd);padding-top:15px;font-size:12px;color:var(--muted-foreground,#777)}summary{cursor:pointer;color:var(--foreground,#1c1917)}li{margin:10px 0;line-height:1.7}button:focus-visible,select:focus-visible,summary:focus-visible{outline:2px solid #d25900;outline-offset:3px}@media(max-width:420px){.paper{padding:16px}h2{font-size:25px}.view{padding:9px}.stats{gap:10px}.navigator{flex-wrap:wrap}select{flex-basis:100%}}
</style></head><body>
<div class="kicker">KITH / EMAIL DESIGN COLLECTION</div><h2>Kith email templates</h2>
<p class="intro">Updated to match the app’s amber/copper buttons and stone palette. Reminders put the contact, event, and exact date first. Select any email to explore its full mockup.</p>
<div class="stats"><span><b>12</b> mockups</span><span><b>10</b> active variants</span><span><b>2</b> library designs</span></div>
<div class="toolbar" role="group" aria-label="Email category"><button class="tab" data-group="All" aria-pressed="true">All<span class="count">12</span></button><button class="tab" data-group="Account" aria-pressed="false">Account<span class="count">4</span></button><button class="tab" data-group="Reminders" aria-pressed="false">Reminders<span class="count">6</span></button><button class="tab" data-group="Library" aria-pressed="false">Library<span class="count">2</span></button></div>
<div class="navigator"><select id="email" aria-label="Choose email template"></select><button class="view" id="desktop" aria-pressed="true">Desktop</button><button class="view" id="mobile" aria-pressed="false">Mobile</button></div>
<div class="paper"><div class="envelope"><strong>Kith</strong> &lt;noreply@your-instance&gt;<div class="subject" id="subject"></div><span id="preheader"></span></div><div class="preview-wrap" id="wrap"><iframe title="Kith email mockup" id="preview" sandbox="allow-same-origin"></iframe></div></div>
<div class="bottom"><span><span id="badge" class="badge"></span><span id="position" style="margin-left:10px"></span></span><div class="pagination"><button id="prev" aria-label="Previous email">←</button><button id="next" aria-label="Next email">→</button></div></div>
<div class="detail" id="detail"></div>
<details><summary>Collection scope &amp; implementation notes</summary><p>This is a source-code inventory and design collection, using fictional sample data. “Active flow” identifies an existing delivery path; it does not mean this design is installed. No delivery code has changed.</p><ul id="notes"></ul></details>
<script>const emails=__EMAILS__;const notes=__NOTES__;
const select=document.getElementById('email');let group='All';let filtered=emails;
function show(){const e=emails.find(x=>x.id===select.value);document.getElementById('subject').textContent=e.subject;document.getElementById('preheader').textContent=e.preheader;const frame=document.getElementById('preview');frame.title='Kith email mockup: '+e.name;frame.srcdoc=e.html;const badge=document.getElementById('badge');badge.textContent=e.status;badge.className='badge'+(e.status==='Builder only'?' library':'');document.getElementById('position').textContent=(emails.indexOf(e)+1)+' / 12';const d=document.getElementById('detail');d.replaceChildren();for(const text of ['Source: '+e.source,'Dynamic fields: '+e.fields.join(' · '),'Link validity: '+e.expiry]){const line=document.createElement('div');line.textContent=text;d.appendChild(line)}frame.onload=resize;}
function resize(){const f=document.getElementById('preview');if(f.contentDocument){f.style.height='1px';f.style.height=f.contentDocument.documentElement.scrollHeight+'px'}}
function options(){select.replaceChildren();filtered=emails.filter(e=>group==='All'||e.group===group);for(const e of filtered){const o=document.createElement('option');o.value=e.id;o.textContent=e.name;select.appendChild(o)}show()}
select.onchange=show;document.querySelectorAll('.tab').forEach(b=>b.onclick=()=>{group=b.dataset.group;document.querySelectorAll('.tab').forEach(t=>t.setAttribute('aria-pressed',t===b));options()});
for(const mode of ['desktop','mobile'])document.getElementById(mode).onclick=()=>{document.getElementById('wrap').classList.toggle('mobile',mode==='mobile');for(const m of ['desktop','mobile'])document.getElementById(m).setAttribute('aria-pressed',m===mode);setTimeout(resize,250)};
for(const [id,offset]of [['prev',-1],['next',1]])document.getElementById(id).onclick=()=>{select.selectedIndex=(select.selectedIndex+offset+filtered.length)%filtered.length;show()};
for(const note of notes){const li=document.createElement('li');li.textContent=note;document.getElementById('notes').appendChild(li)}
window.addEventListener('resize',resize);options();select.value='birthday-today';show();console.log('Kith email gallery: '+emails.length+' mockups; '+emails.filter(e=>e.status==='Active flow').length+' active variants.');
</script></body></html>'''
gallery = GALLERY.replace('__EMAILS__', json.dumps(EMAILS, ensure_ascii=False).replace('</', '<\\/')).replace('__NOTES__', json.dumps(inventory['notes'], ensure_ascii=False))
(ROOT / "index.html").write_text(gallery)
print(f"Built {len(EMAILS)} email mockups and gallery at {ROOT / 'index.html'}")
