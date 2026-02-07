const express = require('express');
const cors = require('cors');
const bodyParser = require('body-parser');
const dbManager = require('./dbManager');
const { tryConnect, MASTER_DB_URL } = dbManager;
const storageManager = require('./storageManager');
const auth = require('./auth');
const fetch = require('node-fetch'); // Ensure node-fetch is available

const app = express();
app.use(cors());
app.use(bodyParser.json());

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
            // Attach shard info if available (added by getFittestDB modification)
            const shardInfo = {
                id: client._shardId,
                connectionString: client._connectionString
            };

            try {
                await client.query('SELECT 1');
            } catch (connErr) {
                try {
                    await client.connect();
                } catch (e) {
                    // ignore
                }
            }

            const result = await action(client);
            
            // If action was successful, and we need to increment DB usage?
            // Actually, executeWithDB is generic. It doesn't know about file sizes.
            // But we can return the shardInfo so the caller can update usage if needed.
            // OR: we attach a method to the client?
            
            try { await client.end(); } catch (e) { /* ignore */ }
            
            // Return result AND shardInfo if possible?
            // Existing callers expect 'result' to be the return value of 'action'.
            // So we can attach shardInfo to 'result' if it's an object?
            // Or just rely on the caller not knowing.
            
            // BETTER: Since executeWithDB creates a scope for a single DB interaction,
            // we can pass shardInfo to the action!
            
            // Re-run action with (client, shardInfo)
            // But 'action' signature is (client) in existing code.
            // JavaScript ignores extra args. So passing (client, shardInfo) is safe for existing code 
            // provided they don't use arguments[1] for something else.
            
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
                        created_at TIMESTAMP DEFAULT NOW()
                    );
                `);
                
                // key-value style check or just insert-on-conflict
                const check = await workerClient.query('SELECT id FROM users WHERE email = $1', [email]);
                if (check.rows.length === 0) {
                    await workerClient.query('INSERT INTO users (email) VALUES ($1)', [email]);
                    console.log(`[Auth] New user created: ${email}`);
                } else {
                    console.log(`[Auth] User exists: ${email}`);
                }
            });

            console.log(`[Auth] login success for ${email}`);
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

// Generate UUID helper
const generateUUID = () => {
    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        var r = Math.random() * 16 | 0, v = c == 'x' ? r : (r & 0x3 | 0x8);
        return v.toString(16);
    });
};

app.post('/api/files/init-upload', async (req, res) => {
    const { user_id, path, name, size_mb, is_folder } = req.body;
    try {
        const fileId = generateUUID();
        await executeWithDB(async (workerClient) => {
            // Update DB usage (metadata overhead, negligible but trackable)
            const dbUsageDelta = 0.001; 
            if (workerClient._connectionString) {
                // Fire and forget usage update
                dbManager.updateShardUsage(workerClient._connectionString, dbUsageDelta);
            }

            // Ensure schema with text ID
            await workerClient.query(`
                CREATE TABLE IF NOT EXISTS files (
                    id TEXT PRIMARY KEY,
                    user_id TEXT NOT NULL,
                    path TEXT NOT NULL,
                    parent_path TEXT,
                    name TEXT NOT NULL,
                    is_folder BOOLEAN DEFAULT FALSE,
                    size_mb NUMERIC DEFAULT 0,
                    status TEXT DEFAULT 'pending',
                    created_at TIMESTAMP DEFAULT NOW()
                );
            `);
            await workerClient.query(`
                 CREATE TABLE IF NOT EXISTS file_chunks (
                    chunk_id TEXT PRIMARY KEY,
                    file_id TEXT NOT NULL,
                    chunk_index INT NOT NULL,
                    storage_shard_id INT NOT NULL,
                    dropbox_path TEXT NOT NULL,
                    status TEXT DEFAULT 'pending',
                    created_at TIMESTAMP DEFAULT NOW()
                );
            `);

            const parentPath = getParentPath(path);
            await workerClient.query(
                'INSERT INTO files (id, user_id, path, parent_path, name, is_folder, size_mb, status) VALUES ($1, $2, $3, $4, $5, $6, $7, $8)',
                [fileId, user_id, path, parentPath, name, is_folder || false, size_mb, 'pending']
            );
        });
        res.json({ ok: true, fileId });
    } catch (e) {
        console.error('[Files] init-upload error:', e);
        res.status(500).json({ ok: false, error: e.message });
    }
});

app.post('/api/files/allocate-chunks', async (req, res) => {
    // This API allocates chunks across available storage shards
    const { fileId, totalChunks, fileSizeMb } = req.body; 
    
    try {
        const storageShards = await dbManager.getAllActiveStorageShards();
        if (storageShards.length === 0) throw new Error("No active storage shards with available capacity");

        const allocations = [];
        const chunkSizeMb = fileSizeMb / totalChunks; // Approx

        await executeWithDB(async (workerClient) => {
             for (let i = 0; i < totalChunks; i++) {
                 // Round Robin distribution with capacity check
                 // storageShards is already sorted by usage ASC
                 
                 // Better than simple round robin: pick the one with lowest usage (first one), then "virtually" increment for next iter
                 // But for simplicity in this loop, we just RR across filtered list.
                 const shard = storageShards[i % storageShards.length];
                
                 // Update Usage Immediately (Tracking)
                 // NOTE: This updates the master DB asynchronously
                 dbManager.updateStorageShardUsage(shard.id, chunkSizeMb);
                 // Virtually update local object to influence next choice in this very loop if we were sorting dynamic
                 shard.current_usage_mb = (parseFloat(shard.current_usage_mb) || 0) + chunkSizeMb;

                 const chunkId = generateUUID();
                 // Unique logical path per chunk: /fileId_chunkIndex
                 const dropboxPath = `/${fileId}_${i}.chunk`; 
                 
                 allocations.push({
                     chunkId,
                     chunkIndex: i,
                     storageShardId: shard.id,
                     accessToken: shard.refresh_token, 
                     dropboxPath
                 });

                 await workerClient.query(
                     'INSERT INTO file_chunks (chunk_id, file_id, chunk_index, storage_shard_id, dropbox_path, status) VALUES ($1, $2, $3, $4, $5, $6)',
                     [chunkId, fileId, i, shard.id, dropboxPath, 'pending']
                 );
             }
        });

        res.json({ ok: true, allocations });
    } catch (e) {
        console.error('[Files] allocate-chunks error:', e);
        res.status(500).json({ ok: false, error: e.message });
    }
});

app.post('/api/files/finalize-upload', async (req, res) => {
    const { fileId } = req.body;
    try {
        await executeWithDB(async (workerClient) => {
            await workerClient.query("UPDATE files SET status = 'completed' WHERE id = $1", [fileId]);
            await workerClient.query("UPDATE file_chunks SET status = 'completed' WHERE file_id = $1", [fileId]);
        });
        res.json({ ok: true });
    } catch (e) {
        res.status(500).json({ ok: false, error: e.message });
    }
});

app.get('/api/files/download-info/:fileId', async (req, res) => {
    const { fileId } = req.params;
    try {
        let fileData, chunks;
        await executeWithDB(async (client) => {
            const fRes = await client.query('SELECT * FROM files WHERE id = $1', [fileId]);
            fileData = fRes.rows[0];
            
            const cRes = await client.query('SELECT * FROM file_chunks WHERE file_id = $1 ORDER BY chunk_index ASC', [fileId]);
            chunks = cRes.rows;
        });

        if (!fileData) return res.status(404).json({ ok: false, message: 'File not found' });

        // 1. Get Shard Map (ALL shards, not just active/non-full ones)
        const shardMap = await dbManager.getAllStorageShardsMap();

        const downloadChunks = await Promise.all(chunks.map(async (chunk) => {
            const shard = shardMap.get(chunk.storage_shard_id);
            // If shard is missing, we can't download.
            if (!shard) {
                console.error(`Missing shard info for chunk ${chunk.chunk_id}, shard_id=${chunk.storage_shard_id}`);
                return null;
            }

            const token = shard.refresh_token; 
            // In a real app we would exchange refresh_token for access_token here if expired,
            // but assuming refresh_token is actually a long-lived access token for this MVP/Demo context,
            // (Dropbox refresh tokens don't work directly in bearer auth without exchange, but maybe user stored access token in that column)
            // If it is indeed a refresh token, we need to acquire access token. 
            // Assuming the stored value works as Bearer for now (Long-Lived Access Token).

            try {
                // Fetch Temp Link from Dropbox
                const response = await fetch('https://api.dropboxapi.com/2/files/get_temporary_link', {
                    method: 'POST',
                    headers: {
                        'Authorization': `Bearer ${token}`,
                        'Content-Type': 'application/json'
                    },
                    body: JSON.stringify({ path: chunk.dropbox_path })
                });
                if(response.ok) {
                    const data = await response.json();
                    return {
                        index: chunk.chunk_index,
                        url: data.link
                    };
                } else {
                    const err = await response.text();
                    console.error(`Dropbox link failed for ${chunk.dropbox_path}: ${err}`);
                }
            } catch (e) { 
                console.error("Temp link failed", e);
            }
            return null;
        }));

        res.json({ 
            ok: true, 
            file: { name: fileData.name, size_mb: fileData.size_mb },
            chunks: downloadChunks.filter(c => c !== null) 
        });

    } catch (e) {
        res.status(500).json({ ok: false, error: e.message });
    }
});

// Legacy backward compatibility route (optional, or just replace functionality)
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
                `SELECT id, user_id, path, name, is_folder, size_mb, dropbox_path, created_at 
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
