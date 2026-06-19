CREATE TABLE saved_objects (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    name TEXT NOT NULL,                    -- "Mi tomatodo"
    description TEXT,                      -- Auto-generada o manual
    embedding BLOB NOT NULL,               -- Vector 1280D de MobileNetV2 (DEPRECATED - usar embeddings table)
    thumbnail BLOB,                        -- Imagen 100x100px
    category TEXT,                         -- "personal", "medicina", "casa"
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    last_seen TIMESTAMP,
    times_found INTEGER DEFAULT 0,        -- Contador de veces encontrado
    user_id TEXT                          -- Para sync con backend
);

-- Nueva tabla para múltiples embeddings por objeto
CREATE TABLE object_embeddings (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    object_id INTEGER NOT NULL,           -- FK a saved_objects.id
    embedding BLOB NOT NULL,              -- Vector 1280D de MobileNetV2
    angle_description TEXT,               -- "frontal", "izquierda", "derecha", "arriba", "abajo"
    image BLOB,                           -- Imagen original capturada
    captured_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (object_id) REFERENCES saved_objects(id) ON DELETE CASCADE
);

CREATE INDEX idx_name ON saved_objects(name);
CREATE INDEX idx_last_seen ON saved_objects(last_seen DESC);
CREATE INDEX idx_object_embeddings ON object_embeddings(object_id);
CREATE INDEX idx_angle ON object_embeddings(angle_description);

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