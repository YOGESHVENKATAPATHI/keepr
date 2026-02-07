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

const app = express();
app.use(cors());
app.use(bodyParser.json());

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
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.path} - body: ${JSON.stringify(req.body)} - query: ${JSON.stringify(req.query)} - ip: ${req.ip}`);
  next();
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
            // Persist user in the worker DB
            await executeWithDB(async (workerClient) => {
                await workerClient.query(`
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
                await ensureUsersSchema(workerClient);
                
                // key-value style check or just insert-on-conflict
                const check = await workerClient.query('SELECT id FROM users WHERE email = $1', [email]);
                if (check.rows.length === 0) {
                    await workerClient.query('INSERT INTO users (email, email_verified) VALUES ($1, true)', [email]);
                    console.log(`[Auth] New user created: ${email}`);
                } else {
                    // ensure email_verified true
                    await workerClient.query('UPDATE users SET email_verified = TRUE WHERE email = $1', [email]);
                    console.log(`[Auth] User exists: ${email}`);
                }

                // Ensure auth tables exist
                await workerClient.query(`
                    CREATE TABLE IF NOT EXISTS auth_tokens (
                        id SERIAL PRIMARY KEY,
                        user_id INT NOT NULL,
                        token TEXT UNIQUE NOT NULL,
                        device_info TEXT,
                        created_at TIMESTAMP DEFAULT NOW(),
                        revoked BOOLEAN DEFAULT FALSE
                    );
                `);

                await workerClient.query(`
                    CREATE TABLE IF NOT EXISTS pin_resets (
                        id SERIAL PRIMARY KEY,
                        user_id INT NOT NULL,
                        reset_token TEXT UNIQUE NOT NULL,
                        expires_at TIMESTAMP NOT NULL,
                        used BOOLEAN DEFAULT FALSE,
                        created_at TIMESTAMP DEFAULT NOW()
                    );
                `);
            });

            console.log(`[Auth] login success for ${email}`);
            // For backwards compatibility we still return a mock token here; clients should transition to real tokens via Google Sign-In or PIN flows.
            res.status(200).send({ message: 'Login successful', token: 'mock-jwt-token' });
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

    try {
        const row = await executeWithDB(async (client) => {
            const r = await client.query('SELECT user_id, revoked FROM auth_tokens WHERE token = $1', [token]);
            return r.rows[0];
        });
        if (!row || row.revoked) return res.status(401).send({ message: 'Invalid or revoked token' });
        req.user = { id: row.user_id, token };
        next();
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
            let userId;
            if (q.rows.length === 0) {
                const ins = await client.query('INSERT INTO users (email, email_verified) VALUES ($1, TRUE) RETURNING id', [email]);
                userId = ins.rows[0].id;
                console.log('[Auth] created user via Google:', email);
            } else {
                userId = q.rows[0].id;
                await client.query('UPDATE users SET email_verified = TRUE WHERE id = $1', [userId]);
                console.log('[Auth] updated user via Google:', email);
            }

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
    if (!pin || !/^\d{6}$/.test(pin)) return res.status(400).send({ message: 'Pin must be 6 digits' });
    const hash = await bcrypt.hash(pin, 10);

    try {
        await executeWithDB(async (client) => {
            await client.query('UPDATE users SET pin_hash=$1 WHERE id=$2', [hash, req.user.id]);
        });
        res.json({ ok: true });
    } catch (e) {
        console.error('Set pin failed', e);
        res.status(500).send({ message: 'Failed to set pin' });
    }
});

// GET /api/auth/profile - returns basic profile if token is valid
app.get('/api/auth/profile', verifyAuthToken, async (req, res) => {
    try {
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

// 2. Allocate Chunk: Decide where to put a specific chunk
app.post('/api/upload/allocate-chunk', async (req, res) => {
    const { fileId, chunkIndex, sizeMb } = req.body;
    // console.log(`[Upload] allocating chunk ${chunkIndex} for ${fileId} (${sizeMb}MB)`);
    
    try {
        // Round-robin or Load Balancer Logic
        // For now, simpler: Pick fittest account for this chunk Size
        // Ideally we iterate available shards or cache them. 
        const account = await storageManager.getFittestStorageAccount(sizeMb);
        
        // Return instructions
        // We will store this chunk at /keepr_chunks/<fileId>/<index> on the chosen shard
        const remotePath = `/keepr_chunks/${fileId}/${chunkIndex}.bin`;
        
        res.json({
            shardId: account.shard_id,
            accessToken: account.access_token,
            uploadPath: remotePath
        });
    } catch(e) {
        console.error('Allocate Chunk Failed', e);
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

                // CHECK: Avoid duplicate entries for same file_id + chunk_index
                const existing = await client.query(
                    'SELECT 1 FROM file_chunks WHERE file_id=$1 AND chunk_index=$2',
                    [fileId, c.index]
                );

                if (existing.rowCount > 0) {
                    console.log(`Skipping duplicate chunk for file=${fileId} index=${c.index}`);
                    continue;
                }

                // DATA INTEGRITY: Insert into shard columns and persist size_mb when available
                try {
                    const insertQuery = `INSERT INTO file_chunks 
                      (file_id, chunk_index, shard_id, storage_shard_id, dropbox_path, size_mb, status) 
                     VALUES ($1, $2, $3, $3, $4, $5, 'completed')`;
                    await client.query(insertQuery, [fileId, c.index, safeShardId, c.path, sizeMb]);
                } catch (insertErr) {
                    // FALLBACK 1: Maybe 'shard_id' column doesn't exist? Try only storage_shard_id
                    if (insertErr.message && insertErr.message.includes('shard_id')) {
                         try {
                            await client.query(
                                `INSERT INTO file_chunks 
                                  (file_id, chunk_index, storage_shard_id, dropbox_path, size_mb, status) 
                                 VALUES ($1, $2, $3, $4, $5, 'completed')`,
                                [fileId, c.index, safeShardId, c.path, sizeMb]
                            );
                            continue; // Success
                         } catch (e2) { /* ignore, try next fallback */ }
                    }

                    // FALLBACK 2: Explicit chunk_id needed?
                    if (insertErr.message && (insertErr.message.includes('chunk_id') || insertErr.message.includes('violate'))) {
                        console.warn('Fallback insert with manual chunk_id');
                        await client.query(
                            `INSERT INTO file_chunks 
                              (chunk_id, file_id, chunk_index, shard_id, storage_shard_id, dropbox_path, size_mb, status) 
                             VALUES ($1, $2, $3, $4, $4, $5, $6, 'completed')`,
                            [Math.floor(Math.random() * 10000000), fileId, c.index, safeShardId, c.path, sizeMb] // $1..$6
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
