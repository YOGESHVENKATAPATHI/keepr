const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');
const dbManager = require('./dbManager');
const { tryConnect, MASTER_DB_URL } = dbManager;
const storageManager = require('./storageManager');
const auth = require('./auth');
const bcrypt = require('bcryptjs');
const { v4: uuidv4 } = require('uuid');
const fetch = require('node-fetch'); // Ensure node-fetch is available
const deletionWorker = require('./deletionWorker');
const cleanupService = require('./cleanupService');
const PDFDocument = require('pdfkit');
const { Document, Packer, Paragraph, TextRun, ImageRun } = require('docx');

const app = express();
app.use(cors());
app.use(bodyParser.json());

// Start background worker
deletionWorker.startDeletionWorker();

// Helpful startup checks
const requiredEnv = ['GOOGLE_CLIENT_ID', 'EMAIL_USER', 'EMAIL_PASS', 'FRONTEND_BASE_URL'];
const missing = requiredEnv.filter(k => !process.env[k]);
if (missing.length > 0) {
    console.warn('[Startup] Warning: Missing env vars:', missing.join(', '));
    console.warn('[Startup] Please add these to your .env to ensure features (Google sign-in, email) work.');
}

process.on('unhandledRejection', (reason, p) => {
    console.error('[Startup] Unhandled Rejection at:', p, 'reason:', reason);
});
process.on('uncaughtException', (err) => {
    console.error('[Startup] Uncaught Exception:', err);
});

// Request logging middleware
app.use((req, res, next) => {
    if (process.env.LOG_VERBOSE_HTTP === 'true') {
        console.log(`[${new Date().toISOString()}] ${req.method} ${req.path} - body: ${JSON.stringify(req.body)} - query: ${JSON.stringify(req.query)} - ip: ${req.ip}`);
    }
  next();
});

const tokenCache = new Map();
const TOKEN_CACHE_TTL_MS = 10 * 60 * 1000;

function getTokenCache(token) {
        const cached = tokenCache.get(token);
        if (!cached) return null;
        if (cached.expiresAt < Date.now()) {
                tokenCache.delete(token);
                return null;
        }
        return cached.user;
}

function setTokenCache(token, user) {
        tokenCache.set(token, {
                user,
                expiresAt: Date.now() + TOKEN_CACHE_TTL_MS
        });
}

// Admin Wipe Endpoint (Added)
app.post('/api/admin/wipe', async (req, res) => {
    const { password } = req.body;
    if (password !== 'y06esh1972005') {
        return res.status(401).send({ message: 'Unauthorized' });
    }

    // Trigger full wipe asynchronously?
    // User wants "complete wipe out ... after entering"
    // Vercel serverless has timeout limits (10s on hobby).
    // The recursive file deletion or table truncation can take > 10s.
    // However, if we just truncate tables and delete root folders from Dropbox, it's fast (O(1)).
    // Dropbox API call is fast. DB call is fast.
    // So we can do it synchronously within ~5s hopefully.
    
    try {
        console.log('[Admin] Wipe requested...');
        const log = await cleanupService.performFullWipe();
        res.json({ message: 'Full wipe completed successfully', log });
    } catch (e) {
        console.error('[Admin] Wipe failed:', e);
        res.status(500).send({ message: 'Wipe failed', error: e.message });
    }
});

// Initialize Registry on Start
// Run init but don't crash the server if Master DB is unreachable; start in degraded mode and allow health checks / admin fixes
dbManager.initMasterRegistry().catch(err => {
    console.error('Master Registry init failed, starting in degraded mode:', err.message);
});

// Health test for DB connectivity
app.get('/api/health/db', async (req, res) => {
    let client;
    try {
        client = await tryConnect(MASTER_DB_URL);
        await client.query('SELECT 1');
        res.json({ ok: true });
    } catch (e) {
        res.status(500).json({ ok: false, error: e.message });
    } finally {
        if (client) try { await client.end(); } catch(e) {}
    }
});


// Helper to execute DB actions with retries and transient error handling
async function executeWithDB(action, maxAttempts = 3) {
    let attempt = 0;
    let lastErr = null;
    while (attempt < maxAttempts) {
        attempt++;
        let client = null;
        try {
            client = await dbManager.getFittestDB();
            // getFittestDB may return a connected client (tryConnectWithRetries returns connected client)
            // but ensure it's connected
            try {
                await client.query('SELECT 1');
            } catch (connErr) {
                // If client isn't connected, try connecting (depends on implementation)
                try {
                    await client.connect();
                } catch (e) {
                    // ignore - will be handled below
                }
            }

            const result = await action(client);
            try { await client.end(); } catch (e) { /* ignore */ }
            return result;
        } catch (e) {
            lastErr = e;
            console.warn(`DB action attempt ${attempt} failed: ${e.code || e.message}`);

            // Handle Missing Table/Column Schema Issues (Lazy Migration)
            if (e.code === '42P01' || e.code === '42703') { // undefined_table OR undefined_column
                console.log(`[DB] Schema mismatch detected (${e.code}). Attempting to auto-migrate schema on shard...`);
                if (client) {
                    try {
                        await ensureWorkerTables(client);
                        console.log('[DB] auto-migration applied successfully. Retrying action...');
                        // Don't close client here if possible, or reconnect? 
                        // Actually, ensureWorkerTables uses the client. 
                        // After migration, we should continue the loop to retry the ACTION.
                        // But we need to close the client first to avoid leaks if we get a NEW client in next iteration.
                        // Wait... we can just retry the action with the SAME client? 
                        // No, the instruction says "executeWithDB(async (client) => ...)" where client is scoped.
                        // So we must continue the loop to get a fresh client or just retry. 
                        // The loop gets a *new* client each time. 
                        // So we should fix the schema on *this* shard (which we have a client for).
                        // Note: getFittestDB might return a different shard next time? 
                        // Good point. We should fix it on the current client.
                        
                        // But wait! If we fix it on 'client', then 'client.end()' happens, then loop continues.
                        // The next iteration calls 'getFittestDB()'. If it returns the SAME shard, good. 
                        // If it returns a DIFFERENT shard, we might hit the error again on that shard.
                        // This corresponds well to "create every tables as needed" - we fix it wherever we are.
                        
                        // We continue the loop.
                    } catch (schemaErr) {
                        console.error('[DB] Auto-migration failed:', schemaErr);
                        // If migration fails, the next retry will likely fail too, but let's stick to the loop.
                    } finally {
                        try { await client.end(); } catch (_) {}
                    }
                    // Wait a bit before retry
                    await new Promise(r => setTimeout(r, 500));
                    continue; 
                }
            }

            // classify transient errors (DNS / connection / timeout)
            const msg = (e && e.message) ? e.message.toLowerCase() : '';
            const transient = e.code === 'ENOTFOUND' || e.code === 'ECONNREFUSED' || msg.includes('getaddrinfo') || msg.includes('timeout');
            if (!transient) {
                // fatal, rethrow
                if (client) try { await client.end(); } catch(_){}
                throw e;
            }
            // transient: wait and retry (exponential backoff)
            if (client) try { await client.end(); } catch(_){}
            await new Promise(r => setTimeout(r, Math.pow(2, attempt) * 500));
            continue;
        }
    }
    throw lastErr;
}

// Ensure all necessary tables exist on a worker DB
async function ensureWorkerTables(client) {
    // 1. Users & Auth (Basic)
    await ensureUsersSchema(client);

    // 2. Auth Tokens (Session)
    await client.query(`
        CREATE TABLE IF NOT EXISTS auth_tokens (
            id SERIAL PRIMARY KEY,
            user_id INT NOT NULL,
            token TEXT UNIQUE NOT NULL,
            device_info TEXT,
            created_at TIMESTAMP DEFAULT NOW(),
            revoked BOOLEAN DEFAULT FALSE
        );
    `);
    
    // 3. Pre-Users (Onboarding)
    await client.query(`
        CREATE TABLE IF NOT EXISTS pre_users (
            token TEXT PRIMARY KEY,
            email TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT NOW()
        );
    `);
    
    // 4. Files Table (Metadata)
    await client.query(`
        CREATE TABLE IF NOT EXISTS files (
            id SERIAL PRIMARY KEY,
            user_id INT NOT NULL,
            path TEXT NOT NULL,
            parent_path TEXT,
            name TEXT NOT NULL,
            is_folder BOOLEAN DEFAULT FALSE,
            size_mb NUMERIC,
            dropbox_path TEXT,
            file_id_ref TEXT,
            created_at TIMESTAMP DEFAULT NOW(),
            updated_at TIMESTAMP DEFAULT NOW()
        );
    `);
    // Add columns if they are missing (migration for older schemas)
    await client.query("ALTER TABLE files ADD COLUMN IF NOT EXISTS file_id_ref TEXT");
    await client.query("ALTER TABLE files ADD COLUMN IF NOT EXISTS dropbox_path TEXT");
    
    // 5. File Chunks (Split content)
    await client.query(`
        CREATE TABLE IF NOT EXISTS file_chunks (
            chunk_id TEXT PRIMARY KEY, 
            file_id INT NOT NULL,
            chunk_index INT NOT NULL,
            shard_id INT NOT NULL,
            size_mb NUMERIC,
            status VARCHAR(50) DEFAULT 'pending',
            dropbox_path TEXT,
            created_at TIMESTAMP DEFAULT NOW()
        );
    `);

    // Fix: Ensure chunk_id exists if table was created previously without it
    // Note: If table exists but has different PK, this might fail or need simpler alter.
    // If 'chunk_id' is missing, we add it. 
    await client.query("ALTER TABLE file_chunks ADD COLUMN IF NOT EXISTS chunk_id TEXT");

    // 6. File Uploads (Status tracking for large files)
    await client.query(`
        CREATE TABLE IF NOT EXISTS file_uploads (
            file_id TEXT PRIMARY KEY,
            user_id INT NOT NULL,
            file_path TEXT NOT NULL,
            total_chunks INT NOT NULL,
            total_size_mb NUMERIC,
            status VARCHAR(50) DEFAULT 'pending',
            created_at TIMESTAMP DEFAULT NOW()
        );
    `);

    // 7. PIN reset tokens
    await client.query(`
        CREATE TABLE IF NOT EXISTS pin_resets (
            id SERIAL PRIMARY KEY,
            user_id INT NOT NULL,
            reset_token TEXT UNIQUE NOT NULL,
            expires_at TIMESTAMP NOT NULL,
            used BOOLEAN DEFAULT FALSE,
            created_at TIMESTAMP DEFAULT NOW()
        );
    `);

    // 8. Saved messages (no cross-table references to avoid shard coupling)
    await client.query(`
        CREATE TABLE IF NOT EXISTS saved_messages (
            id SERIAL PRIMARY KEY,
            user_id INT NOT NULL,
            message_text TEXT NOT NULL,
            tags JSONB DEFAULT '[]'::jsonb,
            is_pinned BOOLEAN DEFAULT FALSE,
            created_at TIMESTAMP DEFAULT NOW(),
            updated_at TIMESTAMP DEFAULT NOW()
        );
    `);
    await client.query(`
        CREATE INDEX IF NOT EXISTS idx_saved_messages_user_pinned_created
        ON saved_messages (user_id, is_pinned DESC, created_at DESC);
    `);

    // 9. Notes (no foreign keys; shard-local records)
    await client.query(`
        CREATE TABLE IF NOT EXISTS user_notes (
            id SERIAL PRIMARY KEY,
            user_id INT NOT NULL,
            title TEXT NOT NULL,
            content_text TEXT DEFAULT '',
            content_json JSONB DEFAULT '{}'::jsonb,
            created_at TIMESTAMP DEFAULT NOW(),
            updated_at TIMESTAMP DEFAULT NOW()
        );
    `);
    await client.query(`
        CREATE INDEX IF NOT EXISTS idx_user_notes_user_updated
        ON user_notes (user_id, updated_at DESC);
    `);

    // 10. Note assets (no foreign keys)
    await client.query(`
        CREATE TABLE IF NOT EXISTS note_assets (
            id SERIAL PRIMARY KEY,
            note_id INT NOT NULL,
            user_id INT NOT NULL,
            asset_name TEXT NOT NULL,
            mime_type TEXT,
            size_mb NUMERIC,
            dropbox_path TEXT NOT NULL,
            storage_source TEXT NOT NULL DEFAULT 'storage_shards',
            storage_shard_ref TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT NOW()
        );
    `);
    await client.query(`
        CREATE INDEX IF NOT EXISTS idx_note_assets_note_user_created
        ON note_assets (note_id, user_id, created_at DESC);
    `);

    await client.query(`
        CREATE TABLE IF NOT EXISTS latex_documents (
            id SERIAL PRIMARY KEY,
            user_id INT NOT NULL,
            title TEXT NOT NULL,
            source_text TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT NOW(),
            updated_at TIMESTAMP DEFAULT NOW()
        );
    `);
    await client.query(`
        CREATE INDEX IF NOT EXISTS idx_latex_documents_user_updated
        ON latex_documents (user_id, updated_at DESC);
    `);

    console.log('[DB] Worker tables ensured.');
}


// Helper to execute query on ALL active DBs and aggregate results
async function executeOnAllDBs(action) {
    const connections = await dbManager.getAllWorkerDBs();
    if (connections.length === 0) throw new Error("No database connections available");

    const promises = connections.map(async ({ id, client, isMaster }) => {
        try {
            const data = await action(client);
            return data; // Array of results from this shard
        } catch (e) {
            console.error(`Query failed on DB ${id}:`, e.message);
            return []; // Return empty on failure to allow partial results
        } finally {
             try { await client.end(); } catch (_) {}
        }
    });

    const resultsArray = await Promise.all(promises);
    // Flatten
    return resultsArray.flat(); 
}

// --- DB Migration Utilities ---
// Ensure users table has expected columns on older schemas
async function ensureUsersSchema(client) {
    // NOTE: We use ALTER TABLE ADD COLUMN IF NOT EXISTS to migrate older worker schemas
    await client.query("ALTER TABLE users ADD COLUMN IF NOT EXISTS email_verified BOOLEAN DEFAULT FALSE");
    await client.query("ALTER TABLE users ADD COLUMN IF NOT EXISTS pin_hash TEXT");
    await client.query("ALTER TABLE users ADD COLUMN IF NOT EXISTS last_failed_pin_attempts INT DEFAULT 0");
    await client.query("ALTER TABLE users ADD COLUMN IF NOT EXISTS pin_locked_until TIMESTAMP NULL");
}

async function ensureMessagesAndNotesSchema(client) {
    await client.query(`
        CREATE TABLE IF NOT EXISTS saved_messages (
            id SERIAL PRIMARY KEY,
            user_id INT NOT NULL,
            message_text TEXT NOT NULL,
            tags JSONB DEFAULT '[]'::jsonb,
            is_pinned BOOLEAN DEFAULT FALSE,
            created_at TIMESTAMP DEFAULT NOW(),
            updated_at TIMESTAMP DEFAULT NOW()
        );
    `);

    await client.query(`
        CREATE TABLE IF NOT EXISTS user_notes (
            id SERIAL PRIMARY KEY,
            user_id INT NOT NULL,
            title TEXT NOT NULL,
            content_text TEXT DEFAULT '',
            content_json JSONB DEFAULT '{}'::jsonb,
            created_at TIMESTAMP DEFAULT NOW(),
            updated_at TIMESTAMP DEFAULT NOW()
        );
    `);

    await client.query(`
        CREATE TABLE IF NOT EXISTS note_assets (
            id SERIAL PRIMARY KEY,
            note_id INT NOT NULL,
            user_id INT NOT NULL,
            asset_name TEXT NOT NULL,
            mime_type TEXT,
            size_mb NUMERIC,
            dropbox_path TEXT NOT NULL,
            storage_source TEXT NOT NULL DEFAULT 'storage_shards',
            storage_shard_ref TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT NOW()
        );
    `);

    await client.query(`
        CREATE TABLE IF NOT EXISTS latex_documents (
            id SERIAL PRIMARY KEY,
            user_id INT NOT NULL,
            title TEXT NOT NULL,
            source_text TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT NOW(),
            updated_at TIMESTAMP DEFAULT NOW()
        );
    `);
}

function requireProvisionedUser(req, res, next) {
    if (!req.user || !req.user.id || req.user.preUser) {
        return res.status(403).send({ message: 'Complete account setup first.' });
    }
    return next();
}

function buildTextExport(note, assets) {
    const lines = [
        `Title: ${note.title || ''}`,
        '',
        note.content_text || ''
    ];
    return Buffer.from(lines.join('\n'), 'utf8');
}

function inferImageType(asset) {
    const mimeType = String(asset.mime_type || '').toLowerCase();
    const assetName = String(asset.asset_name || '').toLowerCase();

    if (mimeType.includes('png') || assetName.endsWith('.png')) return 'png';
    if (mimeType.includes('jpeg') || mimeType.includes('jpg') || assetName.endsWith('.jpg') || assetName.endsWith('.jpeg')) return 'jpg';
    if (mimeType.includes('gif') || assetName.endsWith('.gif')) return 'gif';
    if (mimeType.includes('bmp') || assetName.endsWith('.bmp')) return 'bmp';
    return null;
}

function getImageDimensions(buffer) {
    if (!Buffer.isBuffer(buffer)) {
        buffer = Buffer.from(buffer);
    }

    if (buffer.length >= 24 && buffer.readUInt32BE(0) === 0x89504e47) {
        return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) };
    }

    if (buffer.length >= 10 && buffer.toString('ascii', 0, 3) === 'GIF') {
        return { width: buffer.readUInt16LE(6), height: buffer.readUInt16LE(8) };
    }

    if (buffer.length >= 26 && buffer.toString('ascii', 0, 2) === 'BM') {
        return { width: Math.abs(buffer.readInt32LE(18)), height: Math.abs(buffer.readInt32LE(22)) };
    }

    if (buffer.length >= 4 && buffer.readUInt16BE(0) === 0xffd8) {
        let offset = 2;
        while (offset + 9 < buffer.length) {
            if (buffer[offset] !== 0xff) {
                offset += 1;
                continue;
            }

            const marker = buffer[offset + 1];
            if (marker === 0xd9 || marker === 0xda) break;

            const segmentLength = buffer.readUInt16BE(offset + 2);
            const isStartOfFrame = [0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb].includes(marker);
            if (isStartOfFrame) {
                return {
                    height: buffer.readUInt16BE(offset + 5),
                    width: buffer.readUInt16BE(offset + 7),
                };
            }

            offset += 2 + segmentLength;
        }
    }

    return { width: 1200, height: 800 };
}

async function fetchNoteAssetBuffer(asset) {
    const accessToken = await storageManager.getAccessTokenForReference({
        storageSource: asset.storage_source || 'storage_shards',
        shardRef: String(asset.storage_shard_ref || ''),
    });

    const linkResponse = await fetch('https://api.dropboxapi.com/2/files/get_temporary_link', {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${accessToken}`,
            'Content-Type': 'application/json'
        },
        body: JSON.stringify({ path: String(asset.dropbox_path || '') })
    });

    if (!linkResponse.ok) {
        const text = await linkResponse.text();
        throw new Error(`Dropbox temporary link failed: ${text}`);
    }

    const payload = await linkResponse.json();
    if (!payload.link) {
        throw new Error('Missing temporary link for asset');
    }

    const mediaResponse = await fetch(payload.link);
    if (!mediaResponse.ok) {
        const text = await mediaResponse.text();
        throw new Error(`Asset download failed: ${text}`);
    }

    return mediaResponse.buffer();
}

async function fetchNoteImageData(asset) {
    const buffer = await fetchNoteAssetBuffer(asset);
    const type = inferImageType(asset);

    if (!type) {
        throw new Error(`Unsupported image type for ${asset.asset_name || 'attachment'}`);
    }

    return {
        buffer,
        type,
        ...getImageDimensions(buffer),
    };
}

function buildNoteContentBlocks(note, assets) {
    const assetByName = new Map((assets || []).map((asset) => [String(asset.asset_name || ''), asset]));
    const lines = String(note.content_text || '').split(/\r?\n/);
    const blocks = [];

    for (const line of lines) {
        const trimmed = line.trim();

        if (!trimmed) {
            blocks.push({ type: 'blank' });
            continue;
        }

        const imageMatch = trimmed.match(/^!\[[^\]]*\]\(asset:([^\)]+)\)$/);
        if (imageMatch) {
            const asset = assetByName.get(imageMatch[1]);
            if (asset) {
                blocks.push({ type: 'image', asset });
                continue;
            }
        }

        blocks.push({ type: 'text', text: line });
    }

    return blocks;
}

async function buildDocxExport(note, assets) {
    const children = [
        new Paragraph({
            children: [new TextRun({ text: note.title || 'Untitled note', bold: true, size: 32 })]
        }),
        new Paragraph({ text: '' }),
    ];

    const blocks = buildNoteContentBlocks(note, assets);

    for (const block of blocks) {
        if (block.type === 'blank') {
            children.push(new Paragraph({ text: '' }));
            continue;
        }

        if (block.type === 'image') {
            const imageData = await fetchNoteImageData(block.asset);
            children.push(new Paragraph({
                spacing: { after: 240 },
                children: [
                    new ImageRun({
                        type: imageData.type,
                        data: imageData.buffer,
                        transformation: {
                            width: Math.max(1, imageData.width),
                            height: Math.max(1, imageData.height),
                        },
                    }),
                ],
            }));
            continue;
        }

        children.push(new Paragraph({ text: block.text }));
    }

    const doc = new Document({
        sections: [{ children }]
    });

    return Packer.toBuffer(doc);
}

function renderPdfImage(doc, buffer, width, height) {
    const maxWidth = doc.page.width - doc.page.margins.left - doc.page.margins.right;
    const maxHeight = 360;
    const scale = Math.min(maxWidth / width, maxHeight / height, 1);
    const drawWidth = Math.max(1, Math.round(width * scale));
    const drawHeight = Math.max(1, Math.round(height * scale));

    if (doc.y + drawHeight > doc.page.height - doc.page.margins.bottom) {
        doc.addPage();
    }

    doc.image(buffer, doc.page.margins.left, doc.y, {
        width: drawWidth,
        height: drawHeight,
    });
    doc.moveDown(0.5);
}

async function buildPdfExport(note, assets) {
    const blocks = buildNoteContentBlocks(note, assets);

    return new Promise((resolve, reject) => {
        try {
            const doc = new PDFDocument({ margin: 40 });
            const chunks = [];
            doc.on('data', (chunk) => chunks.push(chunk));
            doc.on('end', () => resolve(Buffer.concat(chunks)));
            doc.on('error', (err) => reject(err));

            doc.fontSize(18).text(note.title || 'Untitled note');
            doc.moveDown();
            doc.fontSize(12);

            (async () => {
                for (const block of blocks) {
                    if (block.type === 'blank') {
                        doc.moveDown();
                        continue;
                    }

                    if (block.type === 'image') {
                        try {
                            const imageData = await fetchNoteImageData(block.asset);
                            renderPdfImage(doc, imageData.buffer, imageData.width, imageData.height);
                        } catch (err) {
                            doc.text(`[Image unavailable: ${block.asset.asset_name || 'attachment'}]`);
                            doc.moveDown(0.5);
                        }
                        continue;
                    }

                    doc.text(block.text);
                }

                doc.moveDown();
                doc.end();
            })().catch(reject);
        } catch (e) {
            reject(e);
        }
    });
}

// --- AUTH ROUTES ---

app.post('/api/auth/send-otp', async (req, res) => {
    const { email } = req.body;
    console.log(`[Auth] send-otp requested for email=${email}`);
    if (!email) {
        console.warn('[Auth] send-otp missing email');
        return res.status(400).send('Email required');
    }
    
    const success = await auth.sendOTP(email);
    if (success) {
        console.log(`[Auth] OTP sent to ${email}`);
        res.status(200).send({ message: 'OTP sent' });
    } else {
        console.error('[Auth] Failed to send OTP to', email);
        res.status(500).send({ message: 'Failed to send OTP' });
    }
});

app.post('/api/auth/verify-otp', async (req, res) => {
    const { email, otp } = req.body;
    console.log(`[Auth] verify-otp attempt for email=${email}`);
    if (auth.verifyOTP(email, otp)) {
        console.log(`[Auth] OTP verified for ${email}`);
        
        try {
            const result = await executeWithDB(async (client) => {
                // Check if user already exists
                await ensureUsersSchema(client);
                const q = await client.query('SELECT id, pin_hash FROM users WHERE email = $1', [email]);
                
                // Ensure auth_tokens exists
                await client.query(`
                    CREATE TABLE IF NOT EXISTS auth_tokens (
                        id SERIAL PRIMARY KEY,
                        user_id INT NOT NULL,
                        token TEXT UNIQUE NOT NULL,
                        device_info TEXT,
                        created_at TIMESTAMP DEFAULT NOW(),
                        revoked BOOLEAN DEFAULT FALSE
                    );
                `);

                if (q.rows.length > 0) {
                    // User exists - issue full token
                    const userId = q.rows[0].id;
                    const tokenValue = uuidv4();
                    await client.query('INSERT INTO auth_tokens (user_id, token, device_info) VALUES ($1, $2, $3)', [userId, tokenValue, null]); // deviceInfo not passed in verify-otp currently
                    return { token: tokenValue, isNew: false };
                } else {
                    // New user - issue onboarding token
                    await client.query(`
                        CREATE TABLE IF NOT EXISTS pre_users (
                            token TEXT PRIMARY KEY,
                            email TEXT NOT NULL,
                            created_at TIMESTAMP DEFAULT NOW()
                        );
                    `);
                    await client.query(`
                       CREATE INDEX IF NOT EXISTS pre_users_created_idx ON pre_users (created_at);
                    `);
                    
                    const newToken = uuidv4();
                    await client.query('INSERT INTO pre_users (token, email) VALUES ($1, $2)', [newToken, email]);
                    return { token: newToken, isNew: true };
                }
            });

            console.log(`[Auth] Login successful for ${email}. New user: ${result.isNew}`);
            res.status(200).send({ message: 'Login successful', token: result.token });
        } catch (e) {
            console.error(e);
            res.status(500).send({ message: 'Database error during login', error: e.message });
        }
    } else {
        console.warn(`[Auth] Invalid OTP for ${email}`);
        res.status(401).send({ message: 'Invalid OTP' });
    }
});

// --- New Auth Endpoints ---

// Middleware: Verify Revocable Token
async function verifyAuthToken(req, res, next) {
    const header = req.headers['authorization'] || req.headers['Authorization'];
    if (!header) return res.status(401).send({ message: 'Authorization required' });
    const parts = header.split(' ');
    if (parts.length !== 2) return res.status(401).send({ message: 'Invalid Authorization format' });
    const token = parts[1];

    const cachedUser = getTokenCache(token);
    if (cachedUser) {
        req.user = cachedUser;
        return next();
    }

    try {
        // 1) Check for fully-provisioned token in auth_tokens
        const row = await executeWithDB(async (client) => {
            // Ensure auth_tokens table exists
            await client.query(`
                CREATE TABLE IF NOT EXISTS auth_tokens (
                    id SERIAL PRIMARY KEY,
                    user_id INT NOT NULL,
                    token TEXT UNIQUE NOT NULL,
                    device_info TEXT,
                    created_at TIMESTAMP DEFAULT NOW(),
                    revoked BOOLEAN DEFAULT FALSE
                );
            `);
            const r = await client.query('SELECT user_id, revoked FROM auth_tokens WHERE token = $1', [token]);
            return r.rows[0];
        });
        if (row && !row.revoked) {
            req.user = { id: row.user_id, token };
            setTokenCache(token, req.user);
            return next();
        }

        // 2) If not found, allow pre-provisioned onboarding tokens (pre_users)
        const pre = await executeWithDB(async (client) => {
            // ensure pre_users table exists for safety
            await client.query(`
                CREATE TABLE IF NOT EXISTS pre_users (
                    token TEXT PRIMARY KEY,
                    email TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT NOW()
                );
            `);
            // index to accelerate TTL cleanup and lookups
            await client.query(`
                CREATE INDEX IF NOT EXISTS pre_users_created_idx ON pre_users (created_at);
            `);
            const r = await client.query('SELECT email FROM pre_users WHERE token = $1', [token]);
            return r.rows[0];
        });

        if (pre && pre.email) {
            // Allow access but mark as onboarding/pre-user (limited privileges expected by handlers)
            req.user = { id: null, email: pre.email, token, preUser: true };
            setTokenCache(token, req.user);
            return next();
        }

        return res.status(401).send({ message: 'Invalid or revoked token' });
    } catch (e) {
        console.error('Token verification error', e);
        res.status(500).send({ message: 'Token verification failed' });
    }
}

// POST /api/auth/google-signin
app.post('/api/auth/google-signin', async (req, res) => {
    // Accept either an idToken (JWT) or an accessToken (Bearer) from client
    const { idToken, accessToken, deviceInfo } = req.body;
    console.log('[Auth] google-signin called');

    let payload = null;

    try {
        if (idToken) {
            console.log('[Auth] Verifying Google id_token');
            const verified = await auth.verifyGoogleIdToken(idToken);
            if (!verified.ok) return res.status(401).send({ message: 'Invalid Google ID token' });
            payload = verified.payload;
        } else if (accessToken) {
            console.log('[Auth] Verifying Google access_token via userinfo endpoint');
            // Fetch userinfo from Google using access token
            const ures = await fetch('https://www.googleapis.com/oauth2/v3/userinfo', {
                headers: { 'Authorization': `Bearer ${accessToken}` }
            });
            if (!ures.ok) {
                const t = await ures.text();
                console.error('[Auth] google userinfo failed:', ures.status, t);
                return res.status(401).send({ message: 'Invalid Google access token' });
            }
            payload = await ures.json();
        } else {
            return res.status(400).send({ message: 'idToken or accessToken required' });
        }

        const email = payload.email;

        const token = await executeWithDB(async (client) => {
            await client.query(`
                CREATE TABLE IF NOT EXISTS users (
                    id SERIAL PRIMARY KEY,
                    email TEXT UNIQUE NOT NULL,
                    email_verified BOOLEAN DEFAULT FALSE,
                    pin_hash TEXT,
                    last_failed_pin_attempts INT DEFAULT 0,
                    pin_locked_until TIMESTAMP NULL,
                    created_at TIMESTAMP DEFAULT NOW()
                );
            `);
            // Ensure existing worker schema has all required columns
            await ensureUsersSchema(client);

            // insert or update user (we identify users by email only)
            const q = await client.query('SELECT id FROM users WHERE email = $1', [email]);
            if (q.rows.length > 0) {
                // existing fully-provisioned user -> issue auth token as before
                const userId = q.rows[0].id;
                await client.query('UPDATE users SET email_verified = TRUE WHERE id = $1', [userId]);
                console.log('[Auth] updated user via Google:', email);

                // ensure auth_tokens table
                await client.query(`
                    CREATE TABLE IF NOT EXISTS auth_tokens (
                        id SERIAL PRIMARY KEY,
                        user_id INT NOT NULL,
                        token TEXT UNIQUE NOT NULL,
                        device_info TEXT,
                        created_at TIMESTAMP DEFAULT NOW(),
                        revoked BOOLEAN DEFAULT FALSE
                    );
                `);

                const tokenValue = uuidv4();
                await client.query('INSERT INTO auth_tokens (user_id, token, device_info) VALUES ($1, $2, $3)', [userId, tokenValue, deviceInfo || null]);
                return tokenValue;
            }

            // New user -> create onboarding (pre_user) token instead of creating a users row.
            await client.query(`
                CREATE TABLE IF NOT EXISTS pre_users (
                    token TEXT PRIMARY KEY,
                    email TEXT NOT NULL,
                    created_at TIMESTAMP DEFAULT NOW()
                );
            `);
            // Ensure index exists for efficient expiry/deletes
            await client.query(`
                CREATE INDEX IF NOT EXISTS pre_users_created_idx ON pre_users (created_at);
            `);
            const onboardingToken = uuidv4();
            await client.query('INSERT INTO pre_users (token, email) VALUES ($1, $2)', [onboardingToken, email]);
            console.log('[Auth] onboarding token issued for new Google user:', email);
            return onboardingToken;
        });

        res.json({ token });
    } catch (e) {
        console.error('Google sign-in failed', e);
        res.status(500).send({ message: 'Google sign-in failed', error: e.message });
    }
});

// POST /api/auth/set-pin (authenticated)
app.post('/api/auth/set-pin', verifyAuthToken, async (req, res) => {
    const { pin } = req.body;
    console.log(`[Auth] set-pin requested for user/email=${req.user?.id ?? req.user?.email} pinLength=${pin ? pin.length : 0}`);

    if (!pin || !/^\d{6}$/.test(pin)) {
        console.warn(`[Auth] Invalid PIN format for user/email=${req.user?.id ?? req.user?.email}`);
        return res.status(400).send({ message: 'Pin must be 6 digits' });
    }

    const hash = await bcrypt.hash(pin, 10);

    try {
        if (req.user?.preUser) {
            // Complete onboarding: create users row, attach the existing onboarding token
            const created = await executeWithDB(async (client) => {
                await client.query(`
                    CREATE TABLE IF NOT EXISTS users (
                        id SERIAL PRIMARY KEY,
                        email TEXT UNIQUE NOT NULL,
                        email_verified BOOLEAN DEFAULT FALSE,
                        pin_hash TEXT,
                        last_failed_pin_attempts INT DEFAULT 0,
                        pin_locked_until TIMESTAMP NULL,
                        created_at TIMESTAMP DEFAULT NOW()
                    );
                `);
                await ensureUsersSchema(client);

                // Insert new user (or return existing id if race)
                let userId = null;
                const q = await client.query('SELECT id FROM users WHERE email = $1', [req.user.email]);
                if (q.rows.length === 0) {
                    const ins = await client.query('INSERT INTO users (email, email_verified, pin_hash) VALUES ($1, TRUE, $2) RETURNING id', [req.user.email, hash]);
                    userId = ins.rows[0].id;
                } else {
                    userId = q.rows[0].id;
                    await client.query('UPDATE users SET pin_hash=$1, email_verified = TRUE WHERE id=$2', [hash, userId]);
                }

                // Ensure auth_tokens table and attach onboarding token for continued auth
                await client.query(`
                    CREATE TABLE IF NOT EXISTS auth_tokens (
                        id SERIAL PRIMARY KEY,
                        user_id INT NOT NULL,
                        token TEXT UNIQUE NOT NULL,
                        device_info TEXT,
                        created_at TIMESTAMP DEFAULT NOW(),
                        revoked BOOLEAN DEFAULT FALSE
                    );
                `);

                // Move token from pre_users into auth_tokens for this user
                await client.query('INSERT INTO auth_tokens (user_id, token, device_info) VALUES ($1, $2, $3)', [userId, req.user.token, null]);

                // Remove pre_users onboarding record
                await client.query('DELETE FROM pre_users WHERE token = $1', [req.user.token]);

                return userId;
            });

            console.log(`[Auth] Completed onboarding and set PIN for userId=${created}`);
            return res.json({ ok: true });
        }

        // Normal path for already-provisioned users
        await executeWithDB(async (client) => {
            await client.query('UPDATE users SET pin_hash=$1 WHERE id=$2', [hash, req.user.id]);
        });
        console.log(`[Auth] PIN set successfully for userId=${req.user.id}`);
        res.json({ ok: true });
    } catch (e) {
        console.error(`Set pin failed for user/email=${req.user?.id ?? req.user?.email}`, e);
        res.status(500).send({ message: 'Failed to set pin' });
    }
});

// GET /api/auth/profile - returns basic profile if token is valid
app.get('/api/auth/profile', verifyAuthToken, async (req, res) => {
    try {
        // If token corresponds to onboarding (pre-user), return email + has_pin=false
        if (req.user?.preUser) {
            return res.json({ profile: { email: req.user.email, has_pin: false } });
        }

        const profile = await executeWithDB(async (client) => {
            const u = await client.query('SELECT email, (pin_hash IS NOT NULL) AS has_pin FROM users WHERE id=$1', [req.user.id]);
            if (u.rows.length === 0) throw new Error('User not found');
            return { email: u.rows[0].email, has_pin: u.rows[0].has_pin };
        });
        res.json({ profile });
    } catch (e) {
        console.error('Profile fetch failed', e);
        res.status(500).send({ message: 'Failed to fetch profile' });
    }
});

// POST /api/auth/pin-login
app.post('/api/auth/pin-login', async (req, res) => {
    const { email, pin, deviceInfo } = req.body;
    if (!email || !pin) return res.status(400).send({ message: 'Email and pin required' });

    try {
        const result = await executeWithDB(async (client) => {
            const u = await client.query('SELECT id, pin_hash, last_failed_pin_attempts, pin_locked_until FROM users WHERE email=$1', [email]);
            if (u.rows.length === 0) return { error: 'User not found' };
            const user = u.rows[0];

            // optional: check lockout
            if (user.pin_locked_until && new Date(user.pin_locked_until) > new Date()) return { error: 'Too many failed attempts. Try later.' };

            if (!user.pin_hash) return { error: 'Pin not set' };

            const ok = await bcrypt.compare(pin, user.pin_hash);
            if (!ok) {
                const attempts = (user.last_failed_pin_attempts || 0) + 1;
                let lockUntil = null;
                if (attempts >= 5) {
                    // lock for 15 minutes
                    const d = new Date(Date.now() + 15 * 60 * 1000);
                    lockUntil = d.toISOString();
                }
                await client.query('UPDATE users SET last_failed_pin_attempts=$1, pin_locked_until=$2 WHERE id=$3', [attempts, lockUntil, user.id]);
                return { error: 'Invalid pin' };
            }

            // success: reset attempts and issue token
            await client.query('UPDATE users SET last_failed_pin_attempts=0, pin_locked_until=NULL WHERE id=$1', [user.id]);

            await client.query(`
                CREATE TABLE IF NOT EXISTS auth_tokens (
                    id SERIAL PRIMARY KEY,
                    user_id INT NOT NULL,
                    token TEXT UNIQUE NOT NULL,
                    device_info TEXT,
                    created_at TIMESTAMP DEFAULT NOW(),
                    revoked BOOLEAN DEFAULT FALSE
                );
            `);

            const tokenValue = uuidv4();
            await client.query('INSERT INTO auth_tokens (user_id, token, device_info) VALUES ($1, $2, $3)', [user.id, tokenValue, deviceInfo || null]);
            return { token: tokenValue };
        });

        if (result.error) return res.status(401).send({ message: result.error });
        res.json({ token: result.token });
    } catch (e) {
        console.error('Pin login failed', e);
        res.status(500).send({ message: 'Pin login failed', error: e.message });
    }
});

// POST /api/auth/request-pin-reset
app.post('/api/auth/request-pin-reset', async (req, res) => {
    const { email, resetUrlBase } = req.body;
    if (!email) return res.status(400).send({ message: 'Email required' });

    try {
        const ok = await executeWithDB(async (client) => {
            const u = await client.query('SELECT id FROM users WHERE email=$1', [email]);
            if (u.rows.length === 0) return false;
            const userId = u.rows[0].id;
            const token = uuidv4();
            const expiresAt = new Date(Date.now() + 60 * 60 * 1000).toISOString(); // 1 hour
            await client.query('INSERT INTO pin_resets (user_id, reset_token, expires_at) VALUES ($1, $2, $3)', [userId, token, expiresAt]);

            // send email
            const base = resetUrlBase || process.env.PIN_RESET_URL || 'https://keepr-gold.vercel.app/pin-reset?token=';
            const sent = await auth.sendPinResetEmail(email, token, base);
            return sent;
        });

        if (!ok) return res.status(400).send({ message: 'Email not found or failed to send' });
        res.json({ ok: true });
    } catch (e) {
        console.error('Request pin reset failed', e);
        res.status(500).send({ message: 'Request pin reset failed' });
    }
});

// POST /api/auth/confirm-pin-reset
app.post('/api/auth/confirm-pin-reset', async (req, res) => {
    const { resetToken, newPin } = req.body;
    if (!resetToken || !newPin || !/^\d{6}$/.test(newPin)) return res.status(400).send({ message: 'Invalid input' });

    try {
        const ok = await executeWithDB(async (client) => {
            const r = await client.query('SELECT id, user_id, expires_at, used FROM pin_resets WHERE reset_token=$1', [resetToken]);
            if (r.rows.length === 0) return { error: 'Invalid token' };
            const row = r.rows[0];
            if (row.used) return { error: 'Token already used' };
            if (new Date(row.expires_at) < new Date()) return { error: 'Token expired' };

            const hash = await bcrypt.hash(newPin, 10);
            await client.query('UPDATE users SET pin_hash=$1 WHERE id=$2', [hash, row.user_id]);
            await client.query('UPDATE pin_resets SET used=true WHERE id=$1', [row.id]);
            return { ok: true };
        });

        if (ok.error) return res.status(400).send({ message: ok.error });
        res.json({ ok: true });
    } catch (e) {
        console.error('Confirm pin reset failed', e);
        res.status(500).send({ message: 'Confirm pin reset failed' });
    }
});

// POST /api/auth/revoke-token
app.post('/api/auth/revoke-token', verifyAuthToken, async (req, res) => {
    const token = req.user.token;
    try {
        await executeWithDB(async (client) => {
            await client.query('UPDATE auth_tokens SET revoked = TRUE WHERE token = $1', [token]);
            // Optionally remove tokens from sessions or cleanup
        });
        tokenCache.delete(token);
        res.json({ ok: true });
    } catch (e) {
        console.error('Revoke token failed', e);
        res.status(500).send({ message: 'Failed to revoke token' });
    }
});

// --- DEBUG: Echo Google token payload (DEVELOPMENT ONLY)
// Usage: POST /api/debug/google-payload  { idToken?: string, accessToken?: string }
// Enabled only when env var DEBUG_AUTH is set to 'true'
app.post('/api/debug/google-payload', async (req, res) => {
    if (process.env.DEBUG_AUTH !== 'true') {
        return res.status(404).send({ message: 'Not found' });
    }

    const { idToken, accessToken } = req.body || {};
    if (!idToken && !accessToken) return res.status(400).send({ message: 'idToken or accessToken required' });

    try {
        if (idToken) {
            const verified = await auth.verifyGoogleIdToken(idToken);
            if (!verified.ok) return res.status(400).send({ ok: false, error: verified.error });
            return res.json({ ok: true, method: 'id_token', payload: verified.payload });
        }

        // access token path
        const ures = await fetch('https://www.googleapis.com/oauth2/v3/userinfo', {
            headers: { 'Authorization': `Bearer ${accessToken}` }
        });
        if (!ures.ok) {
            const t = await ures.text();
            return res.status(400).send({ ok: false, error: t });
        }
        const payload = await ures.json();
        return res.json({ ok: true, method: 'access_token', payload });
    } catch (e) {
        console.error('Debug google payload failed', e);
        res.status(500).send({ ok: false, error: e.message });
    }
});

// GET /api/auth/me - returns basic profile for current token
app.get('/api/auth/me', verifyAuthToken, async (req, res) => {
    try {
        const profile = await executeWithDB(async (client) => {
            const r = await client.query('SELECT id, email, email_verified, (pin_hash IS NOT NULL) AS has_pin FROM users WHERE id=$1', [req.user.id]);
            return r.rows[0];
        });
        res.json({ profile });
    } catch (e) {
        console.error('Get profile failed', e);
        res.status(500).send({ message: 'Get profile failed' });
    }
});

// --- ADMIN ROUTES (To add shards) ---

app.post('/api/admin/add-db-shard', async (req, res) => {
    // protect this route in production
    const { connectionString, nickname } = req.body;
    console.log('[Admin] add-db-shard called', { connectionString: connectionString ? '***' : null, nickname });
    
    let client;
    try {
        client = await tryConnect(MASTER_DB_URL);
        await client.query(
            'INSERT INTO db_shards (connection_string, nickname) VALUES ($1, $2)',
            [connectionString, nickname]
        );
        res.send('Shard added');
    } catch(e) {
        res.status(500).send(e.message);
    } finally {
        if (client) try { await client.end(); } catch(e) {}
    }
});

app.post('/api/admin/add-storage-shard', async (req, res) => {
    // protect this route in production
    const { refreshToken, appKey, appSecret } = req.body;
    console.log('[Admin] add-storage-shard called', { hasRefreshToken: !!refreshToken, appKey: appKey ? '***' : null });
    
    let client;
    try {
        client = await tryConnect(MASTER_DB_URL);
        await client.query(
            'INSERT INTO storage_shards (refresh_token, app_key, app_secret) VALUES ($1, $2, $3)',
            [refreshToken, appKey, appSecret]
        );
        res.send('Storage shard added');
    } catch(e) {
        res.status(500).send(e.message);
    } finally {
        if (client) try { await client.end(); } catch(e) {}
    }
});


// --- FILE ROUTES ---

app.get('/api/storage/best-account', async (req, res) => {
    const sizeMb = parseFloat(req.query.size_mb || '0');
    console.log(`[Storage] best-account requested for size: ${sizeMb.toFixed(2)}MB`);
    try {
        const account = await storageManager.getFittestStorageAccount(sizeMb);
        console.log(`[Storage] returning shard id=${account.shard_id}`);
        res.json(account);
    } catch (e) {
        console.error('[Storage] best-account error:', e);
        res.status(500).send(e.message);
    }
});

// Helper to get parent path
function getParentPath(fullPath) {
    if (!fullPath || fullPath === '/') return null; // Root has no parent
    if (fullPath.endsWith('/')) fullPath = fullPath.slice(0, -1);
    const lastSlash = fullPath.lastIndexOf('/');
    if (lastSlash <= 0) return '/';
    return fullPath.substring(0, lastSlash);
}

// Files / Folders Metadata Routes
app.post('/api/files/create-folder', async (req, res) => {
    const { user_id, path } = req.body;
    console.log('[Files] create-folder', { user_id, path });
    try {
        await executeWithDB(async (workerClient) => {
            // Ensure schema
            await workerClient.query(`
                CREATE TABLE IF NOT EXISTS files (
                    id SERIAL PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    path TEXT NOT NULL,
                    name TEXT NOT NULL,
                    is_folder BOOLEAN DEFAULT FALSE,
                    size_mb NUMERIC DEFAULT 0,
                    dropbox_path TEXT,
                    created_at TIMESTAMP DEFAULT NOW()
                );
            `);
            // Lazy migration for parent_path
            try {
                await workerClient.query('ALTER TABLE files ADD COLUMN IF NOT EXISTS parent_path TEXT');
            } catch (e) { /* ignore if exists or older pg */ }

            const name = path.split('/').filter(Boolean).pop() || '/';
            const parentPath = getParentPath(path);
            
            await workerClient.query(
                'INSERT INTO files (user_id, path, parent_path, name, is_folder) VALUES ($1, $2, $3, $4, true)',
                [user_id, path, parentPath, name]
            );
        });
        res.json({ ok: true });
    } catch (e) {
        console.error('[Files] create-folder error:', e);
        res.status(500).send({ message: 'Failed to create folder', error: e.message });
    }
});

app.post('/api/files/upload-metadata', async (req, res) => {
    const { user_id, path, name, size_mb, dropbox_path } = req.body;
    console.log('[Files] upload-metadata', { user_id, path, name, size_mb, dropbox_path });
    try {
        await executeWithDB(async (workerClient) => {
            await workerClient.query(`
                CREATE TABLE IF NOT EXISTS files (
                    id SERIAL PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    path TEXT NOT NULL,
                    name TEXT NOT NULL,
                    is_folder BOOLEAN DEFAULT FALSE,
                    size_mb NUMERIC DEFAULT 0,
                    dropbox_path TEXT,
                    created_at TIMESTAMP DEFAULT NOW()
                );
            `);
             try {
                await workerClient.query('ALTER TABLE files ADD COLUMN IF NOT EXISTS parent_path TEXT');
            } catch (e) { /* ignore */ }

            const parentPath = getParentPath(path);
            await workerClient.query(
                'INSERT INTO files (user_id, path, parent_path, name, is_folder, size_mb, dropbox_path) VALUES ($1, $2, $3, $4, false, $5, $6)',
                [user_id, path, parentPath, name, size_mb, dropbox_path]
            );
        });
        res.json({ ok: true });
    } catch (e) {
        console.error('[Files] upload-metadata error:', e);
        res.status(500).send({ message: 'Failed to save file metadata', error: e.message });
    }
});

app.get('/api/files/list', async (req, res) => {
    const user_id = req.query.user_id;
    const path = req.query.path || '/';
    console.log('[Files] list', { user_id, path });
    try {
        // Use executeOnAllDBs to query ALL shards
        const result = await executeOnAllDBs(async (workerClient) => {
             // Ensure schema (idempotent)
            await workerClient.query(`
                CREATE TABLE IF NOT EXISTS files (
                    id SERIAL PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    path TEXT NOT NULL,
                    name TEXT NOT NULL,
                    is_folder BOOLEAN DEFAULT FALSE,
                    size_mb NUMERIC DEFAULT 0,
                    dropbox_path TEXT,
                    created_at TIMESTAMP DEFAULT NOW()
                );
            `);
            try {
                await workerClient.query('ALTER TABLE files ADD COLUMN IF NOT EXISTS parent_path TEXT');
            } catch (e) { /* ignore */ }
            try {
                await workerClient.query('ALTER TABLE files ADD COLUMN IF NOT EXISTS file_id_ref TEXT');
            } catch (e) { /* ignore */ }

            // Temporary Fix: Backfill root parent_path for old files
            // Logic: Files at root (start with / and no other /) should have parent_path = '/'
            try {
                // Only running this for root items to be safe and quick
                await workerClient.query(`
                    UPDATE files 
                    SET parent_path = '/' 
                    WHERE parent_path IS NULL 
                      AND path LIKE '/%' 
                      AND path NOT LIKE '/%/%'
                `);
            } catch (e) { console.warn('Backfill warning:', e.message); }

            // Query this specific shard
            // Also leniently allow NULL parent_path if we are looking for root ('/')
            const q = await workerClient.query(
                `SELECT id, user_id, path, name, is_folder, size_mb, dropbox_path, file_id_ref, created_at 
                 FROM files 
                 WHERE user_id = $1 
                   AND (parent_path = $2 OR ($2 = '/' AND parent_path IS NULL))
                 ORDER BY is_folder DESC, name ASC`,
                [user_id, path]
            );
            console.log(`[Files] DB List Result (Shard): found ${q.rows.length} items`);
            return q.rows;
        });

        console.log(`[Files] list returning total ${result.length} items`);
        // Deduplicate results based on user_id + path (if redundancy issues occur)
        // For a simple list, we return all found.
        res.json({ items: result });
    } catch (e) {
        console.error('[Files] list error:', e);
        res.status(500).send({ message: 'Failed to list files', error: e.message });
    }
});

app.get('/api/files/download-zip', async (req, res) => {
    const { path, user_id } = req.query;
    console.log('[Files] download-zip requested', { path, user_id });
    
    try {
        // 1. Get Token
        const account = await storageManager.getFittestStorageAccount();
        const token = account.access_token;
        
        // 2. Call Dropbox download_zip
        const dbxUrl = 'https://content.dropboxapi.com/2/files/download_zip';
        
        const response = await fetch(dbxUrl, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${token}`,
                'Dropbox-API-Arg': JSON.stringify({ path: path }),
            }
        });

        if (!response.ok) {
            const errText = await response.text();
            // Dropbox specific error handling
            if (response.status === 409) {
                 // path not found etc
                 return res.status(404).send("Folder not found or path error.");
            }
            throw new Error(`Dropbox error: ${response.statusText} - ${errText}`);
        }

        // 3. Stream back to client
        const safeName = (path === '/' ? 'root' : path.split('/').pop()) || 'archive';
        res.setHeader('Content-Type', 'application/zip');
        res.setHeader('Content-Disposition', `attachment; filename="${safeName}.zip"`);
        
        // Pipe the node-fetch body string (buffer) or stream to express res
        response.body.pipe(res);

    } catch (e) {
        console.error("Zip download failed", e);
        res.status(500).send("Zip download failed: " + e.message);
    }
});


// Helper for UUID
function generateUUID() {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        var r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
    });
}
// --- NEW DISTRIBUTED UPLOAD ROUTES ---

// 1. Init Upload: Create Record
app.post('/api/upload/init', async (req, res) => {
    const { user_id, path, name, total_size_mb, total_chunks } = req.body;
    console.log('[Upload] init', { user_id, path, chunks: total_chunks });
    const fileId = generateUUID();
    
    try {
        await executeWithDB(async (client) => {
             await client.query(`
                CREATE TABLE IF NOT EXISTS file_uploads (
                    file_id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    path TEXT NOT NULL,
                    name TEXT,
                    total_size_mb NUMERIC,
                    total_chunks INT,
                    status TEXT DEFAULT 'pending', 
                    created_at TIMESTAMP DEFAULT NOW()
                );
            `);
             await client.query(`
                CREATE TABLE IF NOT EXISTS file_chunks (
                    id SERIAL PRIMARY KEY,
                    file_id TEXT NOT NULL,
                    chunk_index INT NOT NULL,
                    shard_id INT NOT NULL,
                    dropbox_path TEXT NOT NULL,
                    size_mb NUMERIC,
                    status TEXT DEFAULT 'pending'
                );
            `);

            // Schema Evolution: Ensure columns exist if table was created previously
            try {
                await client.query('ALTER TABLE file_chunks ADD COLUMN IF NOT EXISTS shard_id INT');
                await client.query('ALTER TABLE file_chunks ADD COLUMN IF NOT EXISTS size_mb NUMERIC');
                await client.query('ALTER TABLE file_uploads ADD COLUMN IF NOT EXISTS total_chunks INT');
            } catch (e) {
                console.log('Schema update skipped/failed', e.message);
            }
            
            await client.query(
                'INSERT INTO file_uploads (file_id, user_id, path, name, total_size_mb, total_chunks) VALUES ($1, $2, $3, $4, $5, $6)',
                [fileId, user_id, path, name, total_size_mb, total_chunks]
            );
        });
        res.json({ fileId });
    } catch(e) {
        console.error('Init Upload Failed', e);
        res.status(500).send(e.message);
    }
});

app.post('/api/upload/status', async (req, res) => {
    const { fileId } = req.body;
    try {
        const result = await executeWithDB(async (client) => {
            const chunksRes = await client.query(
                'SELECT chunk_index, size_mb, status FROM file_chunks WHERE file_id = $1 AND status = \'uploaded\'',
                [fileId]
            );
            
            const uploadRes = await client.query(
                'SELECT total_chunks FROM file_uploads WHERE file_id = $1',
                [fileId]
            );

            if (uploadRes.rows.length === 0) return null;

            return {
                totalChunks: uploadRes.rows[0].total_chunks,
                completedChunks: chunksRes.rows.map(r => ({
                    index: r.chunk_index,
                    sizeMb: parseFloat(r.size_mb)
                }))
            };
        });

        if (!result) return res.status(404).send({ message: 'Upload not found' });
        res.json(result);
    } catch (e) {
        console.error('Upload Status Error', e);
        res.status(500).send({ message: e.message });
    }
});

// 2. Allocate Chunk: Decide where to put a specific chunk
app.post('/api/upload/allocate-chunk', async (req, res) => {
    const { fileId, chunkIndex, sizeMb } = req.body;
    
    try {
        // 1. Check if already allocated (Idempotency)
        let existing = null;
        await executeWithDB(async (client) => {
            const res = await client.query(
                'SELECT shard_id, dropbox_path FROM file_chunks WHERE file_id=$1 AND chunk_index=$2', 
                [fileId, chunkIndex]
            );
            if (res.rows.length > 0) existing = res.rows[0];
        });

        if (existing) {
             console.log(`[Upload] Chunk ${chunkIndex} already allocated on shard ${existing.shard_id}`);
             const token = await storageManager.getAccessTokenForShard(existing.shard_id);
             return res.json({
                 shardId: existing.shard_id,
                 accessToken: token,
                 uploadPath: existing.dropbox_path
             });
        }

        // 2. Not found, allocate new
        const account = await storageManager.getFittestStorageAccount(sizeMb);
        const remotePath = `/keepr_chunks/${fileId}/${chunkIndex}.bin`;

        // 3. Reserve space in DB (Handle race condition & PK overlaps)
        let allocated = null;
        let attempts = 0;
        
        while (!allocated && attempts < 3) {
            attempts++;
            try {
                // Generate a unique ID for this chunk (Fix for duplicate key error on default '0')
                const newChunkId = generateUUID(); // Use helper or uuidv4

                await executeWithDB(async (client) => {
                     await client.query(
                         `INSERT INTO file_chunks (chunk_id, file_id, chunk_index, shard_id, size_mb, status, dropbox_path) 
                          VALUES ($1, $2, $3, $4, $5, 'pending', $6)`,
                         [newChunkId, fileId, chunkIndex, account.shard_id, sizeMb, remotePath]
                     );
                });
                allocated = { shardId: account.shard_id, uploadPath: remotePath };
            } catch (dbErr) {
                // Check if it's a constraint violation
                if (dbErr.message && (dbErr.message.includes('unique') || dbErr.message.includes('duplicate') || dbErr.code === '23505')) {
                     
                     // A. Check if it's a LOGICAL collision (file_id + chunk_index already exists)
                     let raceExisting = null;
                     await executeWithDB(async (client) => {
                        const res = await client.query(
                            'SELECT shard_id, dropbox_path FROM file_chunks WHERE file_id=$1 AND chunk_index=$2', 
                            [fileId, chunkIndex]
                        );
                        if (res.rows.length > 0) raceExisting = res.rows[0];
                     });
                     
                     if (raceExisting) {
                        console.log(`[Upload] Chunk ${chunkIndex} allocation found existing (race/retry).`);
                        const token = await storageManager.getAccessTokenForShard(raceExisting.shard_id);
                        return res.json({
                            shardId: raceExisting.shard_id,
                            accessToken: token,
                            uploadPath: raceExisting.dropbox_path
                        });
                     }

                     // B. If logical record NOT found, it was a random PK collision (unlikely with UUID) or '0' default collision
                     console.warn(`[Upload] Chunk ${chunkIndex} allocation PK collision (attempt ${attempts}). Retrying...`);
                     continue; // Retry insert loop with new UUID
                }
                throw dbErr; // valid DB error
            }
        }
        
        if (allocated) {
            return res.json({
                shardId: allocated.shardId,
                accessToken: account.access_token,
                uploadPath: allocated.uploadPath
            });
        }
        
        throw new Error("Unable to allocate chunk after multiple retries.");
    } catch(e) {
        console.error('Allocate Chunk Failed', e);
        res.status(500).send(e.message);
    }
});

// 2.5 Cancel Upload: Cleanup partial data
app.post('/api/upload/cancel', async (req, res) => {
    const { fileId } = req.body;
    if (!fileId) return res.status(400).send('fileId required');
    
    console.log(`[Upload] Cancelling upload for fileId=${fileId}`);
    try {
        await executeWithDB(async (client) => {
             // 1. Delete chunks (Metadata)
             await client.query('DELETE FROM file_chunks WHERE file_id=$1', [fileId]);
             // 2. Delete file record (Metadata)
             await client.query('DELETE FROM file_uploads WHERE file_id=$1', [fileId]);
             // 3. Ideally cleanup actual files from storage if possible (deferred)
        });
        res.json({ ok: true });
    } catch (e) {
        console.error('Cancel Upload Failed', e);
        res.status(500).send(e.message);
    }
});

// 3. Finalize Upload: Mark done & Create Searchable File Record
app.post('/api/upload/finalize', async (req, res) => {
    const { fileId, chunks } = req.body; // chunks is array of { index, shardId, path, success }
    console.log(`[Upload] finalizing ${fileId}`);
    
    try {
        await executeWithDB(async (client) => {
            // Update status
            await client.query("UPDATE file_uploads SET status='completed' WHERE file_id=$1", [fileId]);
            
            // DB MIGRATION FIX: Ensure no strict constraints block us if schema drifted
            try {
                await client.query('ALTER TABLE file_chunks ALTER COLUMN shard_id DROP NOT NULL');
            } catch(e) {}
            try {
                await client.query('ALTER TABLE file_chunks ALTER COLUMN storage_shard_id DROP NOT NULL');
            } catch(e) {}
            try {
                await client.query('ALTER TABLE file_chunks ALTER COLUMN chunk_id DROP NOT NULL');
                await client.query("ALTER TABLE file_chunks ALTER COLUMN chunk_id SET DEFAULT 0");
            } catch(e) {}

            // Log chunks
            for (const c of chunks) {
                // Handle case where shardId is missing (legacy/error)
                const safeShardId = c.shardId || c.shard_id || 0; 

                // Convert size (bytes) if provided
                const sizeBytes = c.size || c.size_bytes || 0;
                const sizeMb = sizeBytes ? (sizeBytes / (1024 * 1024)) : null;

                // CHECK: Handle existing (pending) entries or duplicates
                const existing = await client.query(
                    'SELECT 1 FROM file_chunks WHERE file_id=$1 AND chunk_index=$2',
                    [fileId, c.index]
                );

                if (existing.rowCount > 0) {
                    // Update the pending chunk to completed
                    await client.query(
                        `UPDATE file_chunks 
                         SET status='completed', shard_id=$3, dropbox_path=$4, size_mb=$5 
                         WHERE file_id=$1 AND chunk_index=$2`,
                         [fileId, c.index, safeShardId, c.path, sizeMb]
                    );
                    // console.log(`Updated pending chunk for file=${fileId} index=${c.index}`);
                    continue;
                }

                // DATA INTEGRITY: Insert into shard columns and persist size_mb when available
                try {
                    const newChunkId = generateUUID();
                    const insertQuery = `INSERT INTO file_chunks 
                      (chunk_id, file_id, chunk_index, shard_id, storage_shard_id, dropbox_path, size_mb, status) 
                     VALUES ($6, $1, $2, $3, $3, $4, $5, 'completed')`;
                    await client.query(insertQuery, [fileId, c.index, safeShardId, c.path, sizeMb, newChunkId]);
                } catch (insertErr) {
                    // FALLBACK 1: Maybe 'shard_id' column doesn't exist? Try only storage_shard_id
                    if (insertErr.message && insertErr.message.includes('shard_id')) {
                         try {
                            const newChunkId = generateUUID();
                            await client.query(
                                `INSERT INTO file_chunks 
                                  (chunk_id, file_id, chunk_index, storage_shard_id, dropbox_path, size_mb, status) 
                                 VALUES ($6, $1, $2, $3, $4, $5, 'completed')`,
                                [fileId, c.index, safeShardId, c.path, sizeMb, newChunkId]
                            );
                            continue; // Success
                         } catch (e2) { /* ignore, try next fallback */ }
                    }

                    // FALLBACK 2: Explicit chunk_id needed? (Redundant if we already add it, but keep for safety)
                    if (insertErr.message && (insertErr.message.includes('chunk_id') || insertErr.message.includes('violate'))) {
                        console.warn('Fallback insert with generated chunk_id');
                        await client.query(
                            `INSERT INTO file_chunks 
                              (chunk_id, file_id, chunk_index, shard_id, storage_shard_id, dropbox_path, size_mb, status) 
                             VALUES ($1, $2, $3, $4, $4, $5, $6, 'completed')`,
                            [generateUUID(), fileId, c.index, safeShardId, c.path, sizeMb] // $1..$6
                        );
                    } else {
                        console.error("Unknown Insert Error detail:", insertErr);
                         // Last ditch: try basic insert again in case transient
                         throw insertErr;
                    }
                }
            }
            
            // Get original metadata to insert into main 'files' table for listing
            const metaRes = await client.query('SELECT * FROM file_uploads WHERE file_id=$1', [fileId]);
            const meta = metaRes.rows[0];
            
            if (meta) {
                 await client.query(`
                    CREATE TABLE IF NOT EXISTS files (
                        id SERIAL PRIMARY KEY,
                        user_id TEXT NOT NULL,
                        path TEXT NOT NULL,
                        name TEXT NOT NULL,
                        is_folder BOOLEAN DEFAULT FALSE,
                        size_mb NUMERIC DEFAULT 0,
                        dropbox_path TEXT, 
                        parent_path TEXT,
                        file_id_ref TEXT, -- Link to distributed ID
                        created_at TIMESTAMP DEFAULT NOW()
                    );
                `);
                
                 // Add column if missing
                try { await client.query('ALTER TABLE files ADD COLUMN IF NOT EXISTS file_id_ref TEXT'); } catch(e){}

                const parentPath = getParentPath(meta.path);
                
                // Note: dropbox_path is effectively 'distributed://<fileId>' or similar, or specific entry
                // We'll mark it with a special prefix so download knows to look up chunks
                await client.query(
                    'INSERT INTO files (user_id, path, parent_path, name, is_folder, size_mb, dropbox_path, file_id_ref) VALUES ($1, $2, $3, $4, false, $5, $6, $7)',
                    [meta.user_id, meta.path, parentPath, meta.name, meta.total_size_mb, 'distributed', fileId]
                );
            }
        });
        res.json({ ok: true });
    } catch(e) {
         console.error('Finalize Failed', e);
         res.status(500).send(e.message);
    }
});



// 5. Delete File OR Folder (Recursive)
// Handles distributed files, standard files, and entire folders
app.post('/api/files/delete', async (req, res) => {
    const { userId, path } = req.body;
    console.log('[Delete] Request for', path, 'user=', userId);

    try {
        await executeWithDB(async (client) => {
            // Ensure deletion queue table exists
            await client.query(`
                CREATE TABLE IF NOT EXISTS deletion_queue (
                    id SERIAL PRIMARY KEY,
                    shard_id INT NOT NULL,
                    paths TEXT[] NOT NULL,
                    status TEXT DEFAULT 'pending', 
                    retries INT DEFAULT 0,
                    created_at TIMESTAMP DEFAULT NOW()
                );
            `);

            // Function to delete a single file record and its chunks (Batched)
            async function deleteOneFile(file) {
                 if (file.is_folder) return; // safety

                 // Distributed File
                 if (file.dropbox_path === 'distributed' && file.file_id_ref) {
                     // Batch chunk deletion loop to handle millions of chunks
                     let hasMoreChunks = true;
                     while(hasMoreChunks) {
                         // Use ctid (physical row location) to identify rows if 'id' column is missing or for efficient batching
                         const chunkRes = await client.query(
                             'SELECT ctid, shard_id, dropbox_path FROM file_chunks WHERE file_id = $1 LIMIT 1000',
                             [file.file_id_ref]
                         );
                         
                         if (chunkRes.rows.length === 0) {
                             hasMoreChunks = false;
                             break;
                         }

                         const shardMap = {};
                         const chunkCtids = [];
                         for (const c of chunkRes.rows) {
                            if (!shardMap[c.shard_id]) shardMap[c.shard_id] = [];
                            shardMap[c.shard_id].push(c.dropbox_path);
                            chunkCtids.push(c.ctid);
                         }
                         
                         // Insert into deletion queue instead of direct delete
                         for (const sId of Object.keys(shardMap)) {
                             // shardMap[sId] is array of paths
                             await client.query(
                                 'INSERT INTO deletion_queue (shard_id, paths) VALUES ($1, $2)', 
                                 [sId, shardMap[sId]]
                             );
                         }
                         
                         // Delete this batch from DB using ctid
                         // Note: Passing array of ctids requires explicit cast to tid[]
                         await client.query('DELETE FROM file_chunks WHERE ctid = ANY($1::tid[])', [chunkCtids]);
                     }
                     // Clean upload record
                     await client.query('DELETE FROM file_uploads WHERE file_id = $1', [file.file_id_ref]);

                 } else {
                     // Legacy/Simple File
                     // Logic omitted for brevity, assumed cleaned up or handled manually
                 }

                 // Remove from 'files' table
                 await client.query('DELETE FROM files WHERE id = $1', [file.id]);
            }

            // 1. Resolve target
            const targetRes = await client.query('SELECT * FROM files WHERE user_id = $1 AND path = $2', [userId, path]);
            if (targetRes.rows.length === 0) return res.status(404).send("Not found");
            const target = targetRes.rows[0];

            if (target.is_folder) {
                console.log(`[Delete] Deleting folder recursively: ${path}`);
                
                // 1. Delete all descendant files in batches
                while(true) {
                    const fileBatch = await client.query(
                        "SELECT * FROM files WHERE user_id=$1 AND path LIKE $2 AND is_folder=false LIMIT 200", 
                        [userId, path + '/%']
                    );
                    
                    if (fileBatch.rows.length === 0) break;
                    
                    console.log(`[Delete] Processing batch of ${fileBatch.rows.length} files...`);
                    for (const f of fileBatch.rows) {
                        await deleteOneFile(f);
                    }
                }
                
                // 2. Delete all subfolders records
                // Since we don't have FK constraints on parent_path, we can just bulk delete
                await client.query(
                    "DELETE FROM files WHERE user_id=$1 AND path LIKE $2 AND is_folder=true", 
                    [userId, path + '/%']
                );

                // 3. Delete the target folder itself
                await client.query('DELETE FROM files WHERE id = $1', [target.id]);

            } else {
                // Just a file
                await deleteOneFile(target);
            }
            
            res.json({ ok: true });
        });

    } catch(e) {
        console.error('[Delete] Failed', e);
        res.status(500).send(e.message);
    }
});


// 4. Download Info: Get chunk map for a distributed file
app.post('/api/files/download-info', async (req, res) => {
    const { fileIdRef } = req.body;
    console.log('[Download] get info for', fileIdRef);
    
    try {
        const chunks = await executeWithDB(async (client) => {
            const resChunks = await client.query(
                'SELECT chunk_index, shard_id, dropbox_path, size_mb FROM file_chunks WHERE file_id = $1 ORDER BY chunk_index ASC',
                [fileIdRef]
            );
            return resChunks.rows;
        });

        const chunksWithTokens = [];
        const uniqueShardIds = [...new Set(chunks.map(c => c.shard_id))];
        const tokenMap = {};

        // Fetch tokens for all shards involved (connecting to Master DB via storageManager)
        for (const sId of uniqueShardIds) {
            try {
                tokenMap[sId] = await storageManager.getAccessTokenForShard(sId);
            } catch(e) {
                console.error(`Failed to get token for shard ${sId}`, e);
            }
        }

        chunks.forEach(c => {
            if (tokenMap[c.shard_id]) {
                chunksWithTokens.push({
                    index: c.chunk_index,
                    path: c.dropbox_path,
                    token: tokenMap[c.shard_id],
                    size_mb: c.size_mb || null
                });
            }
        });
        
        // Optionally include file-level metadata to help the client verify integrity
        const metaRes = await executeWithDB(async (client) => {
            const r = await client.query('SELECT total_chunks, total_size_mb FROM file_uploads WHERE file_id=$1', [fileIdRef]);
            return r.rows[0];
        });

        chunksWithTokens.sort((a,b) => a.index - b.index);
        res.json({ chunks: chunksWithTokens, total_chunks: metaRes?.total_chunks || null, total_size_mb: metaRes?.total_size_mb || null });

    } catch(e) {
        console.error('Download Info Failed', e);
        res.status(500).send(e.message);
    }
});

// --- SAVED MESSAGES ROUTES ---

app.get('/api/messages/saved', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    try {
        const rows = await executeWithDB(async (client) => {
            const result = await client.query(
                `SELECT id, user_id, message_text, tags, is_pinned, created_at, updated_at
                 FROM saved_messages
                 WHERE user_id = $1
                 ORDER BY is_pinned DESC, created_at DESC`,
                [req.user.id]
            );
            return result.rows;
        });

        res.json({ items: rows });
    } catch (e) {
        console.error('List saved messages failed', e);
        res.status(500).send({ message: 'Failed to list saved messages', error: e.message });
    }
});

app.post('/api/messages/saved', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const { messageText, tags, isPinned } = req.body || {};
    if (!messageText || !String(messageText).trim()) {
        return res.status(400).send({ message: 'messageText is required' });
    }

    try {
        const row = await executeWithDB(async (client) => {
            const result = await client.query(
                `INSERT INTO saved_messages (user_id, message_text, tags, is_pinned)
                 VALUES ($1, $2, $3::jsonb, $4)
                 RETURNING id, user_id, message_text, tags, is_pinned, created_at, updated_at`,
                [
                    req.user.id,
                    String(messageText),
                    JSON.stringify(Array.isArray(tags) ? tags : []),
                    Boolean(isPinned)
                ]
            );
            return result.rows[0];
        });

        res.json({ item: row });
    } catch (e) {
        console.error('Create saved message failed', e);
        res.status(500).send({ message: 'Failed to create saved message', error: e.message });
    }
});

app.delete('/api/messages/saved/:id', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const id = parseInt(req.params.id, 10);
    if (!id) return res.status(400).send({ message: 'Invalid id' });

    try {
        const deleted = await executeWithDB(async (client) => {
            const result = await client.query(
                'DELETE FROM saved_messages WHERE id = $1 AND user_id = $2 RETURNING id',
                [id, req.user.id]
            );
            return result.rowCount > 0;
        });

        if (!deleted) return res.status(404).send({ message: 'Saved message not found' });
        res.json({ ok: true });
    } catch (e) {
        console.error('Delete saved message failed', e);
        res.status(500).send({ message: 'Failed to delete saved message', error: e.message });
    }
});

// --- NOTES ROUTES ---

app.get('/api/notes', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    try {
        const items = await executeWithDB(async (client) => {
            const result = await client.query(
                `SELECT id, user_id, title, content_text, content_json, created_at, updated_at
                 FROM user_notes
                 WHERE user_id = $1
                 ORDER BY updated_at DESC`,
                [req.user.id]
            );
            return result.rows;
        });
        res.json({ items });
    } catch (e) {
        console.error('List notes failed', e);
        res.status(500).send({ message: 'Failed to list notes', error: e.message });
    }
});

app.post('/api/notes', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const { title, contentText, contentJson } = req.body || {};
    const safeTitle = (title && String(title).trim()) ? String(title).trim() : 'Untitled note';

    try {
        const item = await executeWithDB(async (client) => {
            const result = await client.query(
                `INSERT INTO user_notes (user_id, title, content_text, content_json)
                 VALUES ($1, $2, $3, $4::jsonb)
                 RETURNING id, user_id, title, content_text, content_json, created_at, updated_at`,
                [req.user.id, safeTitle, String(contentText || ''), JSON.stringify(contentJson || {})]
            );
            return result.rows[0];
        });
        res.json({ item });
    } catch (e) {
        console.error('Create note failed', e);
        res.status(500).send({ message: 'Failed to create note', error: e.message });
    }
});

app.get('/api/notes/:id', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const id = parseInt(req.params.id, 10);
    if (!id) return res.status(400).send({ message: 'Invalid note id' });

    try {
        const payload = await executeWithDB(async (client) => {
            const noteRes = await client.query(
                `SELECT id, user_id, title, content_text, content_json, created_at, updated_at
                 FROM user_notes
                 WHERE id = $1 AND user_id = $2`,
                [id, req.user.id]
            );
            if (noteRes.rows.length === 0) return null;

            const assetsRes = await client.query(
                `SELECT id, note_id, user_id, asset_name, mime_type, size_mb, dropbox_path, storage_source, storage_shard_ref, created_at
                 FROM note_assets
                 WHERE note_id = $1 AND user_id = $2
                 ORDER BY created_at DESC`,
                [id, req.user.id]
            );

            return {
                item: noteRes.rows[0],
                assets: assetsRes.rows
            };
        });

        if (!payload) return res.status(404).send({ message: 'Note not found' });
        res.json(payload);
    } catch (e) {
        console.error('Get note failed', e);
        res.status(500).send({ message: 'Failed to fetch note', error: e.message });
    }
});

app.put('/api/notes/:id', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const id = parseInt(req.params.id, 10);
    if (!id) return res.status(400).send({ message: 'Invalid note id' });

    const { title, contentText, contentJson } = req.body || {};
    if (!title && contentText === undefined && contentJson === undefined) {
        return res.status(400).send({ message: 'No fields provided to update' });
    }

    try {
        const item = await executeWithDB(async (client) => {
            const existing = await client.query(
                'SELECT id, title, content_text, content_json FROM user_notes WHERE id = $1 AND user_id = $2',
                [id, req.user.id]
            );
            if (existing.rows.length === 0) return null;

            const row = existing.rows[0];
            const nextTitle = title ? String(title) : row.title;
            const nextText = contentText !== undefined ? String(contentText) : row.content_text;
            const nextJson = contentJson !== undefined ? contentJson : row.content_json;

            const updateRes = await client.query(
                `UPDATE user_notes
                 SET title = $1, content_text = $2, content_json = $3::jsonb, updated_at = NOW()
                 WHERE id = $4 AND user_id = $5
                 RETURNING id, user_id, title, content_text, content_json, created_at, updated_at`,
                [nextTitle, nextText, JSON.stringify(nextJson || {}), id, req.user.id]
            );
            return updateRes.rows[0];
        });

        if (!item) return res.status(404).send({ message: 'Note not found' });
        res.json({ item });
    } catch (e) {
        console.error('Update note failed', e);
        res.status(500).send({ message: 'Failed to update note', error: e.message });
    }
});

app.delete('/api/notes/:id', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const id = parseInt(req.params.id, 10);
    if (!id) return res.status(400).send({ message: 'Invalid note id' });

    try {
        const deleted = await executeWithDB(async (client) => {
            await client.query('DELETE FROM note_assets WHERE note_id = $1 AND user_id = $2', [id, req.user.id]);
            const result = await client.query('DELETE FROM user_notes WHERE id = $1 AND user_id = $2 RETURNING id', [id, req.user.id]);
            return result.rowCount > 0;
        });

        if (!deleted) return res.status(404).send({ message: 'Note not found' });
        res.json({ ok: true });
    } catch (e) {
        console.error('Delete note failed', e);
        res.status(500).send({ message: 'Failed to delete note', error: e.message });
    }
});

app.post('/api/notes/:id/media/init', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const noteId = parseInt(req.params.id, 10);
    if (!noteId) return res.status(400).send({ message: 'Invalid note id' });

    const { fileName, mimeType, sizeMb } = req.body || {};
    if (!fileName) return res.status(400).send({ message: 'fileName is required' });

    try {
        const noteExists = await executeWithDB(async (client) => {
            const result = await client.query('SELECT id FROM user_notes WHERE id = $1 AND user_id = $2', [noteId, req.user.id]);
            return result.rows.length > 0;
        });
        if (!noteExists) return res.status(404).send({ message: 'Note not found' });

        const account = await storageManager.getFittestStorageAccountForNotes(parseFloat(sizeMb || 0));
        const safeName = String(fileName).replace(/[^a-zA-Z0-9._-]/g, '_');
        const uploadPath = `/keepr_notes/${req.user.id}/${noteId}/${Date.now()}_${safeName}`;

        res.json({
            accessToken: account.access_token,
            uploadPath,
            storageSource: account.storage_source || 'storage_shards',
            storageShardRef: account.shard_ref || String(account.shard_id)
        });
    } catch (e) {
        console.error('Init note media upload failed', e);
        res.status(500).send({ message: 'Failed to initialize media upload', error: e.message });
    }
});

app.post('/api/notes/:id/media/complete', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const noteId = parseInt(req.params.id, 10);
    if (!noteId) return res.status(400).send({ message: 'Invalid note id' });

    const { assetName, mimeType, sizeMb, dropboxPath, storageSource, storageShardRef } = req.body || {};
    if (!assetName || !dropboxPath || !storageShardRef) {
        return res.status(400).send({ message: 'assetName, dropboxPath, and storageShardRef are required' });
    }

    try {
        const item = await executeWithDB(async (client) => {
            const noteRes = await client.query('SELECT id FROM user_notes WHERE id = $1 AND user_id = $2', [noteId, req.user.id]);
            if (noteRes.rows.length === 0) return null;

            const insertRes = await client.query(
                `INSERT INTO note_assets (note_id, user_id, asset_name, mime_type, size_mb, dropbox_path, storage_source, storage_shard_ref)
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
                 RETURNING id, note_id, user_id, asset_name, mime_type, size_mb, dropbox_path, storage_source, storage_shard_ref, created_at`,
                [
                    noteId,
                    req.user.id,
                    String(assetName),
                    mimeType ? String(mimeType) : null,
                    sizeMb ? parseFloat(sizeMb) : null,
                    String(dropboxPath),
                    storageSource ? String(storageSource) : 'storage_shards',
                    String(storageShardRef)
                ]
            );
            return insertRes.rows[0];
        });

        if (!item) return res.status(404).send({ message: 'Note not found' });
        res.json({ item });
    } catch (e) {
        console.error('Complete note media upload failed', e);
        res.status(500).send({ message: 'Failed to register media upload', error: e.message });
    }
});

app.post('/api/notes/media/temp-link', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const { dropboxPath, storageSource, storageShardRef } = req.body || {};
    if (!dropboxPath || !storageShardRef) {
        return res.status(400).send({ message: 'dropboxPath and storageShardRef are required' });
    }

    try {
        const token = await storageManager.getAccessTokenForReference({
            storageSource: storageSource || 'storage_shards',
            shardRef: String(storageShardRef)
        });

        const response = await fetch('https://api.dropboxapi.com/2/files/get_temporary_link', {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${token}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({ path: String(dropboxPath) })
        });

        if (!response.ok) {
            const text = await response.text();
            throw new Error(`Dropbox temporary link failed: ${text}`);
        }

        const payload = await response.json();
        res.json({ link: payload.link });
    } catch (e) {
        console.error('Get note media temp link failed', e);
        res.status(500).send({ message: 'Failed to get temporary link', error: e.message });
    }
});

app.delete('/api/notes/:id/assets/:assetId', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const id = parseInt(req.params.id, 10);
    const assetId = parseInt(req.params.assetId, 10);
    if (!id || !assetId) return res.status(400).send({ message: 'Invalid id' });

    try {
        const deleted = await executeWithDB(async (client) => {
            const resA = await client.query('SELECT dropbox_path, storage_shard_ref FROM note_assets WHERE id = $1 AND note_id = $2 AND user_id = $3', [assetId, id, req.user.id]);
            if (resA.rows.length === 0) return false;
            
            const asset = resA.rows[0];

            await client.query('BEGIN');
            try {
                await client.query('DELETE FROM note_assets WHERE id = $1', [assetId]);

                // Deletion Worker queues paths to delete. But Note Assets have storage_shard_ref, not internal shard_id integer.
                // Wait, storage_shards has internal id. We can look it up.
                if (asset.storage_shard_ref && asset.dropbox_path) {
                    const s = await client.query('SELECT id FROM storage_shards WHERE id_ref = $1', [asset.storage_shard_ref]);
                    if (s.rows.length > 0) {
                         const shard_id = s.rows[0].id;
                         await client.query(`
                             CREATE TABLE IF NOT EXISTS deletion_queue (
                                 id SERIAL PRIMARY KEY,
                                 shard_id INT NOT NULL,
                                 paths TEXT[] NOT NULL,
                                 status TEXT DEFAULT 'pending',
                                 retries INT DEFAULT 0,
                                 created_at TIMESTAMP DEFAULT NOW()
                             )
                         `);
                         await client.query('INSERT INTO deletion_queue (shard_id, paths) VALUES ($1, $2)', [shard_id, [asset.dropbox_path]]);
                    }
                }

                await client.query('COMMIT');
                return true;
            } catch (txErr) {
                try {
                    await client.query('ROLLBACK');
                } catch (_) {
                    // Ignore rollback errors; the original error is the one we want to surface.
                }
                throw txErr;
            }
        });

        if (!deleted) return res.status(404).send({ message: 'Asset not found' });
        res.json({ ok: true });
    } catch (e) {
        console.error('Delete note asset failed', e);
        res.status(500).send({ message: 'Failed to delete note asset', error: e.message });
    }
});

app.post('/api/notes/:id/export', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const id = parseInt(req.params.id, 10);
    if (!id) return res.status(400).send({ message: 'Invalid note id' });

    const format = String((req.body && req.body.format) || 'txt').toLowerCase();
    if (!['txt', 'pdf', 'docx'].includes(format)) {
        return res.status(400).send({ message: 'Supported formats: txt, pdf, docx' });
    }

    try {
        const payload = await executeWithDB(async (client) => {
            const noteRes = await client.query(
                'SELECT id, title, content_text FROM user_notes WHERE id = $1 AND user_id = $2',
                [id, req.user.id]
            );
            if (noteRes.rows.length === 0) return null;

            const assetsRes = await client.query(
                'SELECT asset_name, mime_type FROM note_assets WHERE note_id = $1 AND user_id = $2 ORDER BY created_at ASC',
                [id, req.user.id]
            );

            return {
                note: noteRes.rows[0],
                assets: assetsRes.rows
            };
        });

        if (!payload) return res.status(404).send({ message: 'Note not found' });

        const safeTitle = String(payload.note.title || 'note').replace(/[^a-zA-Z0-9._-]/g, '_');

        if (format === 'txt') {
            const buffer = buildTextExport(payload.note, payload.assets);
            res.setHeader('Content-Type', 'text/plain; charset=utf-8');
            res.setHeader('Content-Disposition', `attachment; filename="${safeTitle}.txt"`);
            return res.send(buffer);
        }

        if (format === 'pdf') {
            const buffer = await buildPdfExport(payload.note, payload.assets);
            res.setHeader('Content-Type', 'application/pdf');
            res.setHeader('Content-Disposition', `attachment; filename="${safeTitle}.pdf"`);
            return res.send(buffer);
        }

        const buffer = await buildDocxExport(payload.note, payload.assets);
        res.setHeader('Content-Type', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
        res.setHeader('Content-Disposition', `attachment; filename="${safeTitle}.docx"`);
        return res.send(buffer);
    } catch (e) {
        console.error('Export note failed', e);
        res.status(500).send({ message: 'Failed to export note', error: e.message });
    }
});

// --- LATEX DOCUMENT ROUTES (Vercel-safe, no native TeX binaries) ---

app.get('/api/latex/docs', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    try {
        const items = await executeWithDB(async (client) => {
            const r = await client.query(
                `SELECT id, user_id, title, source_text, created_at, updated_at
                 FROM latex_documents
                 WHERE user_id = $1
                 ORDER BY updated_at DESC`,
                [req.user.id]
            );
            return r.rows;
        });
        res.json({ items });
    } catch (e) {
        console.error('List latex docs failed', e);
        res.status(500).send({ message: 'Failed to list latex docs', error: e.message });
    }
});

app.post('/api/latex/docs', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const title = String((req.body && req.body.title) || 'Untitled latex doc').trim();
    const sourceText = String((req.body && req.body.sourceText) || '');
    try {
        const item = await executeWithDB(async (client) => {
            const r = await client.query(
                `INSERT INTO latex_documents (user_id, title, source_text)
                 VALUES ($1, $2, $3)
                 RETURNING id, user_id, title, source_text, created_at, updated_at`,
                [req.user.id, title || 'Untitled latex doc', sourceText]
            );
            return r.rows[0];
        });
        res.json({ item });
    } catch (e) {
        console.error('Create latex doc failed', e);
        res.status(500).send({ message: 'Failed to create latex doc', error: e.message });
    }
});

app.get('/api/latex/docs/:id', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const id = parseInt(req.params.id, 10);
    if (!id) return res.status(400).send({ message: 'Invalid id' });
    try {
        const item = await executeWithDB(async (client) => {
            const r = await client.query(
                `SELECT id, user_id, title, source_text, created_at, updated_at
                 FROM latex_documents
                 WHERE id = $1 AND user_id = $2`,
                [id, req.user.id]
            );
            return r.rows[0] || null;
        });
        if (!item) return res.status(404).send({ message: 'Document not found' });
        res.json({ item });
    } catch (e) {
        console.error('Get latex doc failed', e);
        res.status(500).send({ message: 'Failed to fetch latex doc', error: e.message });
    }
});

app.put('/api/latex/docs/:id', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const id = parseInt(req.params.id, 10);
    if (!id) return res.status(400).send({ message: 'Invalid id' });

    const title = String((req.body && req.body.title) || 'Untitled latex doc').trim();
    const sourceText = String((req.body && req.body.sourceText) || '');
    try {
        const item = await executeWithDB(async (client) => {
            const r = await client.query(
                `UPDATE latex_documents
                 SET title = $1, source_text = $2, updated_at = NOW()
                 WHERE id = $3 AND user_id = $4
                 RETURNING id, user_id, title, source_text, created_at, updated_at`,
                [title || 'Untitled latex doc', sourceText, id, req.user.id]
            );
            return r.rows[0] || null;
        });
        if (!item) return res.status(404).send({ message: 'Document not found' });
        res.json({ item });
    } catch (e) {
        console.error('Update latex doc failed', e);
        res.status(500).send({ message: 'Failed to update latex doc', error: e.message });
    }
});

app.delete('/api/latex/docs/:id', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const id = parseInt(req.params.id, 10);
    if (!id) return res.status(400).send({ message: 'Invalid id' });
    try {
        const deleted = await executeWithDB(async (client) => {
            const r = await client.query('DELETE FROM latex_documents WHERE id = $1 AND user_id = $2 RETURNING id', [id, req.user.id]);
            return r.rowCount > 0;
        });
        if (!deleted) return res.status(404).send({ message: 'Document not found' });
        res.json({ ok: true });
    } catch (e) {
        console.error('Delete latex doc failed', e);
        res.status(500).send({ message: 'Failed to delete latex doc', error: e.message });
    }
});

app.post('/api/latex/docs/:id/export', verifyAuthToken, requireProvisionedUser, async (req, res) => {
    const id = parseInt(req.params.id, 10);
    if (!id) return res.status(400).send({ message: 'Invalid id' });
    const format = String((req.body && req.body.format) || 'tex').toLowerCase();
    if (!['tex', 'txt', 'pdf', 'docx', 'doc'].includes(format)) {
        return res.status(400).send({ message: 'Supported formats: tex, txt, pdf, docx, doc' });
    }

    try {
        const item = await executeWithDB(async (client) => {
            const r = await client.query('SELECT id, title, source_text FROM latex_documents WHERE id = $1 AND user_id = $2', [id, req.user.id]);
            return r.rows[0] || null;
        });

        if (!item) return res.status(404).send({ message: 'Document not found' });

        const safeTitle = String(item.title || 'latex_doc').replace(/[^a-zA-Z0-9._-]/g, '_');
        const textBuffer = Buffer.from(String(item.source_text || ''), 'utf8');

        if (format === 'tex') {
            res.setHeader('Content-Type', 'application/x-tex; charset=utf-8');
            res.setHeader('Content-Disposition', `attachment; filename="${safeTitle}.tex"`);
            return res.send(textBuffer);
        }

        if (format === 'txt') {
            res.setHeader('Content-Type', 'text/plain; charset=utf-8');
            res.setHeader('Content-Disposition', `attachment; filename="${safeTitle}.txt"`);
            return res.send(textBuffer);
        }

        if (format === 'pdf') {
            try {
                const axios = require('axios');
                const formData = new URLSearchParams();
                formData.append('code', String(item.source_text || ''));
                const response = await axios.post('https://rtex.probablyaweb.site/api/v2', formData.toString(), {
                    headers: { 'Content-Type': 'application/x-www-form-urlencoded' }
                });
                
                if (response.data && response.data.status === 'success') {
                    const pdfResponse = await axios.get(`https://rtex.probablyaweb.site/api/v2/${response.data.filename}`, {
                        responseType: 'arraybuffer'
                    });
                    res.setHeader('Content-Type', 'application/pdf');
                    res.setHeader('Content-Disposition', `attachment; filename="${safeTitle}.pdf"`);
                    return res.send(pdfResponse.data);
                } else {
                    res.status(500).send({ message: 'LaTeX PDF API compilation failed: ' + (response.data.description || 'Unknown error') });
                    return;
                }
            } catch (err) {
                console.error('LaTeX PDF API compilation error:', err.message);
                res.status(500).send({ message: 'Failed to compile LaTeX via API', error: err.message });
                return;
            }
        }

        const exportNoteLike = {
            title: item.title,
            content_text: String(item.source_text || '')
        };

        const docx = await buildDocxExport(exportNoteLike, []);
        if (format === 'doc') {
            res.setHeader('Content-Type', 'application/msword');
            res.setHeader('Content-Disposition', `attachment; filename="${safeTitle}.doc"`);
            return res.send(docx);
        }

        res.setHeader('Content-Type', 'application/vnd.openxmlformats-officedocument.wordprocessingml.document');
        res.setHeader('Content-Disposition', `attachment; filename="${safeTitle}.docx"`);
        return res.send(docx);
    } catch (e) {
        console.error('Export latex doc failed', e);
        res.status(500).send({ message: 'Failed to export latex doc', error: e.message });
    }
});

// Health test for SMTP transporter
app.get('/api/health/email', async (req, res) => {
    try {
        // transporter.verify logs errors at startup; we can also call verify here
        const authModule = require('./auth');
        if (typeof authModule.verifyTransport === 'function') {
            const ok = await authModule.verifyTransport();
            return res.json({ ok });
        }
        res.status(500).json({ ok: false, message: 'verifyTransport not available' });
    } catch (e) {
        res.status(500).json({ ok: false, error: e.message });
    }
});

const PORT = process.env.PORT || 3000;

// For local development
if (require.main === module) {
    app.listen(PORT, () => {
        console.log(`Server running on port ${PORT}`);
    });
}

// Export for Vercel serverless deployment
module.exports = app;
