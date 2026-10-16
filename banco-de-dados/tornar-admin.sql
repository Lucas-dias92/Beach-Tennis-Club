-- Troque pelo e-mail com que você se cadastrou no site e rode no SQL Editor do Supabase.
update public.profiles
set is_admin = true
where id = (select id from auth.users where email = 'SEU-EMAIL-AQUI');
