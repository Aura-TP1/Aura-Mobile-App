CREATE TABLE saved_objects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,                    -- "Mi tomatodo"
    description TEXT,                      -- Auto-generada o manual
    embedding BLOB NOT NULL,               -- Vector 1280D de MobileNetV2
    thumbnail BLOB,                        -- Imagen 100x100px
    category TEXT,                         -- "personal", "medicina", "casa"
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen TIMESTAMP,
    times_found INTEGER DEFAULT 0,        -- Contador de veces encontrado
    user_id TEXT                          -- Para sync con backend
);

CREATE INDEX idx_name ON saved_objects(name);
CREATE INDEX idx_last_seen ON saved_objects(last_seen DESC);

CREATE TABLE user_settings (
    id INTEGER PRIMARY KEY CHECK (id = 1), -- Solo 1 fila
    tts_speed REAL DEFAULT 0.85,          -- Velocidad TTS
    tts_volume REAL DEFAULT 0.8,          -- Volumen
    font_size INTEGER DEFAULT 24,         -- Tamaño fuente
    high_contrast BOOLEAN DEFAULT 1,      -- Modo alto contraste
    auto_announce BOOLEAN DEFAULT 1,      -- Auto-anunciar detecciones
    vibration_enabled BOOLEAN DEFAULT 1,
    language TEXT DEFAULT 'es-PE'         -- Español Perú
);

INSERT INTO user_settings DEFAULT VALUES;