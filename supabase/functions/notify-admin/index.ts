// Alerta Tránsito · Aviso al administrador cuando un usuario envía un pago (solicitud de plan)
// Envía WhatsApp (CallMeBot) y correo (Resend). Las claves se guardan como secretos en Supabase:
//   ADMIN_EMAIL, RESEND_API_KEY, CALLMEBOT_PHONE, CALLMEBOT_APIKEY, APP_URL (opcional)
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const cop = (n: number | null) => "$" + Number(n ?? 0).toLocaleString("es-CO");
const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "Método no permitido" }, 405);

  const admin = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const token = (req.headers.get("Authorization") ?? "").replace(/^Bearer\s+/i, "");
  const { data: auth } = await admin.auth.getUser(token);
  const user = auth?.user;
  if (!user) return json({ error: "No autorizado" }, 401);

  let requestId = "";
  try { requestId = (await req.json()).request_id ?? ""; } catch { /* cuerpo vacío */ }
  if (!/^[0-9a-f-]{36}$/i.test(requestId)) return json({ error: "Solicitud inválida" }, 400);

  const { data: r } = await admin.from("plan_requests").select("*").eq("id", requestId).maybeSingle();
  // Solo avisa por solicitudes propias, pendientes y recién creadas (evita reenvíos y abuso)
  if (!r || r.user_id !== user.id || r.status !== "pendiente" ||
      Date.now() - new Date(r.created_at).getTime() > 10 * 60 * 1000) {
    return json({ ok: false, reason: "ignorada" });
  }
  const { data: p } = await admin.from("profiles").select("full_name").eq("id", user.id).maybeSingle();

  const planName = r.plan === "empresa" ? "Empresa" : "Plus";
  const months = r.months ?? 1;
  const who = r.plan === "empresa" && r.company_name ? `${r.company_name} (${p?.full_name || user.email})` : (p?.full_name || user.email || "Usuario");
  const appUrl = Deno.env.get("APP_URL") ?? "https://orion-nova-technologies-s-a-s.github.io/Tr-nsito-IA/";
  const lines = [
    "🔔 *Nuevo pago por revisar* · Alerta Tránsito",
    `Plan: ${planName} · ${months} ${months === 1 ? "mes" : "meses"}`,
    `Valor: ${cop(r.amount)}`,
    `Cliente: ${who}`,
    `Correo: ${user.email ?? "-"}`,
    `Celular: ${r.contact_phone ?? "-"}`,
    r.nit ? `NIT: ${r.nit}` : "",
    `Referencia del pago: ${r.payment_ref ?? "-"}`,
    "",
    "Revisa tu Nequi o banco y aprueba en Admin → Planes:",
    appUrl,
  ].filter((l, i, a) => l !== "" || a[i - 1] !== "");
  const text = lines.join("\n");

  const result: Record<string, string> = {};

  // WhatsApp con CallMeBot (gratis, para avisos a tu propio número)
  const phone = Deno.env.get("CALLMEBOT_PHONE"), cmKey = Deno.env.get("CALLMEBOT_APIKEY");
  if (phone && cmKey) {
    try {
      const u = `https://api.callmebot.com/whatsapp.php?phone=${encodeURIComponent(phone)}&text=${encodeURIComponent(text)}&apikey=${encodeURIComponent(cmKey)}`;
      const res = await fetch(u);
      result.whatsapp = res.ok ? "enviado" : `error ${res.status}`;
    } catch (e) { result.whatsapp = "error " + (e as Error).message; }
  } else result.whatsapp = "sin configurar";

  // Correo con Resend
  const resendKey = Deno.env.get("RESEND_API_KEY"), to = Deno.env.get("ADMIN_EMAIL");
  if (resendKey && to) {
    try {
      const from = Deno.env.get("EMAIL_FROM") ?? "Alerta Tránsito <onboarding@resend.dev>";
      const rows = lines.slice(1, lines.indexOf("")).map((l) => {
        const [k, ...v] = l.split(": ");
        return `<tr><td style="padding:6px 10px;color:#555">${esc(k)}</td><td style="padding:6px 10px;font-weight:600">${esc(v.join(": "))}</td></tr>`;
      }).join("");
      const html = `<div style="font-family:Arial,sans-serif;max-width:520px">
        <h2 style="color:#0B1B4D;margin:0 0 6px">🔔 Nuevo pago por revisar</h2>
        <p style="color:#555;margin:0 0 12px">Un usuario de Alerta Tránsito envió una solicitud de plan con su comprobante de pago.</p>
        <table style="border-collapse:collapse;border:1px solid #e5e7eb;width:100%">${rows}</table>
        <p style="margin:16px 0">Revisa que el dinero haya llegado a tu Nequi o banco y luego apruébalo:</p>
        <a href="${appUrl}" style="background:#1E5EFF;color:#fff;padding:12px 18px;border-radius:10px;text-decoration:none;font-weight:700">Abrir Admin → Planes</a>
        <p style="color:#999;font-size:12px;margin-top:20px">Orion Nova Technologies · Alerta Tránsito</p></div>`;
      const res = await fetch("https://api.resend.com/emails", {
        method: "POST",
        headers: { Authorization: `Bearer ${resendKey}`, "Content-Type": "application/json" },
        body: JSON.stringify({ from, to: [to], subject: `💰 Nuevo pago ${planName} · ${cop(r.amount)} · ${who}`, html, text }),
      });
      result.email = res.ok ? "enviado" : `error ${res.status} ${await res.text()}`;
    } catch (e) { result.email = "error " + (e as Error).message; }
  } else result.email = "sin configurar";

  return json({ ok: true, ...result });
});
