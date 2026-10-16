// Supabase Edge Function: push-lesson (avisos push). Segredos vêm das variáveis de ambiente da função.
import webpush from "npm:web-push@3.6.7";
import { createClient } from "npm:@supabase/supabase-js@2";

webpush.setVapidDetails("https://beachtennisclub.vercel.app", Deno.env.get("VAPID_PUBLIC")!, Deno.env.get("VAPID_PRIVATE")!);

Deno.serve(async (req) => {
  if (req.headers.get("x-push-secret") !== Deno.env.get("PUSH_SECRET")) return new Response("forbidden", { status: 403 });
  const { teacher, user, admins, title, body } = await req.json();
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
  const ids: string[] = [];
  if (user) ids.push(user);
  if (teacher) ids.push(teacher);
  const adminIds = async () => ((await sb.from("profiles").select("id").eq("is_admin", true)).data ?? []).map((a: { id: string }) => a.id);
  if (admins) ids.push(...(await adminIds()));
  let subs = ids.length ? ((await sb.from("push_subscriptions").select("*").in("user_id", ids)).data ?? []) : [];
  // professor sem celular cadastrado (criado pelo admin): o aviso vai para o(s) admin(s)
  if (teacher && !admins && subs.length === 0) {
    const a = await adminIds();
    if (a.length) subs = (await sb.from("push_subscriptions").select("*").in("user_id", a)).data ?? [];
  }
  const payload = JSON.stringify({ title, body, url: "./" });
  let sent = 0;
  await Promise.all(subs.map(async (s: { id: string; endpoint: string; p256dh: string; auth: string }) => {
    try { await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload); sent++; }
    catch (e) { const c = (e as { statusCode?: number }).statusCode; if (c === 404 || c === 410) await sb.from("push_subscriptions").delete().eq("id", s.id); }
  }));
  return new Response(JSON.stringify({ sent }), { headers: { "Content-Type": "application/json" } });
});
