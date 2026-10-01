-- =====================================================================
--  Traitement des SMS reçus pour l'annonce - Schéma PostgreSQL (v4)
--  Canal unique : SMS via SMS Gateway for Android (capcom6 / SMSGate)
--  Clé contact = numéro expéditeur normalisé E.164 (+336..., +337...)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. INBOX : SMS bruts, alimentée en temps réel par loc_01 (sans LLM)
--    Source : webhook "sms:received" de la passerelle
--    { deviceId, event, id, webhookId,
--      payload: { messageId, message, sender, recipient, simNumber, receivedAt } }
-- ---------------------------------------------------------------------
CREATE TABLE inbox (
    id                  BIGSERIAL PRIMARY KEY,
    gateway_message_id  TEXT        NOT NULL UNIQUE,   -- payload.messageId : anti-doublon
                                                       -- (l'app rejoue le webhook jusqu'à 14 fois / ~2 jours
                                                       --  tant qu'elle n'a pas reçu de 2xx)
    from_number         TEXT        NOT NULL,          -- normalisé E.164 par loc_01, ex: +33612345678
    from_raw            TEXT,                          -- payload.sender tel que reçu (diagnostic)
    body                TEXT        NOT NULL,          -- payload.message (multipart déjà réassemblé par l'app)
    sms_at              TIMESTAMPTZ,                   -- payload.receivedAt : heure de réception sur le téléphone
    received_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),  -- heure d'arrivée dans n8n
    status              TEXT        NOT NULL DEFAULT 'pending'
                        CHECK (status IN ('pending', 'processing', 'done', 'error')),
    batch_id            UUID,
    processing_at       TIMESTAMPTZ,                   -- début du traitement (remise en file si bloqué)
    processed_at        TIMESTAMPTZ,
    error               TEXT
);
CREATE INDEX inbox_pending_idx ON inbox (from_number, sms_at) WHERE status = 'pending';

-- ---------------------------------------------------------------------
-- 2. CONTACTS : une ligne par numéro, enrichie à chaque lot (inchangée)
-- ---------------------------------------------------------------------
CREATE TABLE contacts (
    id                  BIGSERIAL PRIMARY KEY,
    telephone           TEXT     NOT NULL UNIQUE,  -- numéro expéditeur E.164 = clé
    -- Coordonnées
    nom                 TEXT,
    prenom              TEXT,
    email               TEXT,        -- si fourni dans le SMS
    -- Projet locatif
    motif               TEXT,        -- pourquoi (mutation, rapprochement, séparation...)
    date_emmenagement   TEXT,        -- quand ("début novembre", "ASAP"...)
    situation_pro       TEXT,        -- CDI, étudiant, retraité...
    revenus             TEXT,
    garant              TEXT,
    nb_adultes          SMALLINT,
    nb_enfants          SMALLINT,
    animaux             TEXT,
    disponibilites      TEXT,        -- créneaux de visite
    souhaits            TEXT,
    questions           TEXT,
    -- Analyse
    extraction          JSONB,       -- sortie complète du LLM
    infos_manquantes    TEXT[],
    resume              TEXT,        -- 1-2 phrases pour le rapport
    score               SMALLINT CHECK (score BETWEEN 0 AND 100),
    classification      TEXT CHECK (classification IN ('spam', 'ignorant', 'prospect', 'premium')),
    is_premium          BOOLEAN  NOT NULL DEFAULT FALSE,
    -- Suivi des échanges
    nb_messages         INTEGER  NOT NULL DEFAULT 0,
    first_message_at    TIMESTAMPTZ,
    last_message_at     TIMESTAMPTZ,
    last_reply_at       TIMESTAMPTZ,   -- anti-flood 3 jours
    nb_replies          INTEGER  NOT NULL DEFAULT 0,
    notes               TEXT,
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------
-- 3. REPLIES : historique des SMS envoyés par loc_04
--    La ligne est créée AVANT l'appel API (status 'queued') ; son id sert
--    d'identifiant idempotent côté passerelle : "loc-reply-<id>".
--    Un nouvel essai avec le même id ne produit pas de second SMS.
-- ---------------------------------------------------------------------
CREATE TABLE replies (
    id                  BIGSERIAL PRIMARY KEY,
    contact_id          BIGINT      NOT NULL REFERENCES contacts (id),
    template            TEXT,                 -- ex: 'prospect_v1', 'premium_v1'
    body                TEXT        NOT NULL, -- texte final, normalisé GSM 7 bits
    gateway_message_id  TEXT        UNIQUE,   -- "loc-reply-<id>", envoyé dans le champ "id" de l'API
    status              TEXT        NOT NULL DEFAULT 'queued'
                        CHECK (status IN ('queued', 'sent', 'delivered', 'failed')),
    error               TEXT,                 -- réponse API en erreur ou payload.reason de sms:failed
    created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status_at           TIMESTAMPTZ
);

-- ---------------------------------------------------------------------
-- 4. GATEWAY_STATUS : signe de vie du téléphone passerelle
--    Alimentée par loc_01 sur les événements "system:ping" et "app:started".
--    Une seule ligne par appareil (deviceId).
-- ---------------------------------------------------------------------
CREATE TABLE gateway_status (
    device_id       TEXT        PRIMARY KEY,
    last_event      TEXT,                 -- 'system:ping', 'app:started', 'sms:received'...
    last_seen_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    last_started_at TIMESTAMPTZ,          -- dernier redémarrage de l'app
    health          JSONB                 -- payload.health du ping (batterie, connectivité...)
);

-- ---------------------------------------------------------------------
-- 5. updated_at automatique
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_updated_at() RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at := NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER contacts_updated_at
    BEFORE UPDATE ON contacts
    FOR EACH ROW EXECUTE FUNCTION set_updated_at();

-- ---------------------------------------------------------------------
-- 6. Vue de suivi, lue par loc_05 (rapport email)
-- ---------------------------------------------------------------------
CREATE VIEW v_suivi AS
SELECT id, is_premium, classification, score, prenom, nom, telephone, email,
       date_emmenagement, motif, situation_pro, nb_adultes, nb_enfants, animaux,
       disponibilites, questions, resume, infos_manquantes,
       nb_messages, last_message_at, last_reply_at
FROM contacts
WHERE classification IN ('prospect', 'premium')
ORDER BY is_premium DESC, score DESC, last_message_at DESC;

-- =====================================================================
--  Requêtes utilisées par les workflows (référence)
-- =====================================================================

-- loc_01 : insertion d'un SMS reçu (répondre 2xx même si doublon)
-- INSERT INTO inbox (gateway_message_id, from_number, from_raw, body, sms_at)
-- VALUES ($1, $2, $3, $4, $5)
-- ON CONFLICT (gateway_message_id) DO NOTHING;

-- loc_01 : signe de vie (system:ping, app:started, et tout autre événement)
-- INSERT INTO gateway_status (device_id, last_event, last_seen_at, health)
-- VALUES ($1, $2, NOW(), $3)
-- ON CONFLICT (device_id) DO UPDATE
--   SET last_event = EXCLUDED.last_event, last_seen_at = NOW(),
--       health = COALESCE(EXCLUDED.health, gateway_status.health);

-- loc_03 étape 1 : verrouiller le lot (UN seul batch_id pour tout le lot)
-- et regrouper les SMS fragmentés par numéro
-- WITH params AS (SELECT gen_random_uuid() AS batch_id),
-- lot AS (
--     UPDATE inbox SET status = 'processing',
--                      batch_id = (SELECT batch_id FROM params),
--                      processing_at = NOW()
--     WHERE id IN (SELECT id FROM inbox WHERE status = 'pending'
--                  FOR UPDATE SKIP LOCKED)
--     RETURNING *
-- )
-- SELECT from_number,
--        MIN(COALESCE(sms_at, received_at)) AS first_at,
--        MAX(COALESCE(sms_at, received_at)) AS last_at,
--        STRING_AGG(body, E'\n---\n' ORDER BY COALESCE(sms_at, received_at)) AS texte_complet,
--        ARRAY_AGG(id) AS inbox_ids,
--        COUNT(*) AS nb_fragments
-- FROM lot
-- GROUP BY from_number;

-- loc_04 : anti-flood (renvoie une ligne = on peut répondre)
-- SELECT id FROM contacts
-- WHERE telephone = $1
--   AND (last_reply_at IS NULL OR last_reply_at < NOW() - INTERVAL '3 days');

-- loc_04 : statut d'envoi remonté par sms:failed / sms:sent (via loc_01)
-- UPDATE replies SET status = $2, error = $3, status_at = NOW()
-- WHERE gateway_message_id = $1;

-- Watchdog : la passerelle est-elle muette depuis plus de 30 min ?
-- SELECT device_id, last_seen_at FROM gateway_status
-- WHERE last_seen_at < NOW() - INTERVAL '30 minutes';

-- Remise en file des messages restés bloqués (ex: crash pendant un lot)
-- UPDATE inbox SET status = 'pending', batch_id = NULL, processing_at = NULL
-- WHERE status = 'processing' AND processing_at < NOW() - INTERVAL '2 hours';
