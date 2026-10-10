-- Alerta Tránsito · Nuevo tipo de reporte "Libre de agentes"
-- Pegar en Supabase > proyecto "Alerta Transito" > SQL Editor > Run (una sola vez)
alter type public.report_type add value if not exists 'via_libre';
