-- Torneios com patrocínio: logos das marcas, premiação e imagem de capa.
alter table public.tournaments add column if not exists sponsors jsonb not null default '[]'::jsonb;
alter table public.tournaments add column if not exists prize text;
alter table public.tournaments add column if not exists banner text;
grant insert (sponsors, prize, banner), update (sponsors, prize, banner) on public.tournaments to authenticated;
