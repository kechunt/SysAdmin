-- Semilla de usuarios (Práctica 8/10). Solo se ejecuta en el primer arranque de db_data.
CREATE TABLE IF NOT EXISTS usuarios (
    id      SERIAL PRIMARY KEY,
    sam     VARCHAR(64) UNIQUE NOT NULL,
    nombre  VARCHAR(128) NOT NULL,
    grupo   VARCHAR(32) NOT NULL,
    creado  TIMESTAMPTZ NOT NULL DEFAULT now()
);

INSERT INTO usuarios (sam, nombre, grupo) VALUES
    ('cuate01',      'Cuate 01',      'Cuates'),
    ('cuate02',      'Cuate 02',      'Cuates'),
    ('cuate03',      'Cuate 03',      'Cuates'),
    ('cuate04',      'Cuate 04',      'Cuates'),
    ('cuate05',      'Cuate 05',      'Cuates'),
    ('nocuate01',    'No Cuate 01',   'NoCuates'),
    ('nocuate02',    'No Cuate 02',   'NoCuates'),
    ('nocuate03',    'No Cuate 03',   'NoCuates'),
    ('nocuate04',    'No Cuate 04',   'NoCuates'),
    ('nocuate05',    'No Cuate 05',   'NoCuates')
ON CONFLICT (sam) DO NOTHING;
