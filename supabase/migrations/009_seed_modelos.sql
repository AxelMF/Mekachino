-- =====================================================================
-- 009_seed_modelos.sql — Modelos de ejemplo por marca (SPEC.md §11).
-- =====================================================================
insert into modelos_vehiculo (marca_id, nombre, anio_desde, anio_hasta, motor)
select m.id, v.nombre, v.anio_desde, v.anio_hasta, v.motor
from (values
  ('Changan', 'CS35 Plus', 2019, 2026, '1.6L'),
  ('Changan', 'CS15', 2018, 2024, '1.5L'),
  ('Changan', 'Alsvin', 2020, 2026, '1.5L'),
  ('KYC', 'T3', 2019, 2025, '1.5L'),
  ('Shineray', 'X30', 2018, 2024, '1.5L'),
  ('Shineray', 'T30', 2020, 2026, '1.8L'),
  ('Jetour', 'X70', 2019, 2025, '1.5T'),
  ('GAC', 'GS3', 2020, 2026, '1.5L'),
  ('Jaecoo', 'J7', 2023, 2026, '1.6T'),
  ('Maxus', 'T60', 2019, 2025, '2.0L')
) as v(marca, nombre, anio_desde, anio_hasta, motor)
join marcas_vehiculo m on m.nombre = v.marca
on conflict (marca_id, nombre, version) do nothing;
