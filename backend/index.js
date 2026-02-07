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
                await client.query('ALTER TABLE file_chunks ALTER COLUMN chunk_id DROP NOT NULL');
            } catch(e) {}

            // Log chunks
            for (const c of chunks) {
                // Handle case where shardId is missing (legacy/error)
                const safeShardId = c.shardId || c.shard_id || 0; 
                
                await client.query(
                    'INSERT INTO file_chunks (file_id, chunk_index, shard_id, dropbox_path, status) VALUES ($1, $2, $3, $4, $5)',
                    [fileId, c.index, safeShardId, c.path, 'completed']
                );
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
        await executeWithDB(async (client) => {
            const resChunks = await client.query(
                'SELECT chunk_index, shard_id, dropbox_path FROM file_chunks WHERE file_id = $1 ORDER BY chunk_index ASC',
                [fileIdRef]
            );
            
            // We need tokens for these shards to give to client
            // This is slightly inefficient (N queries), but simple. 
            // Better: fetch all active shards in memory map.
            const shardsRes = await client.query('SELECT * FROM storage_shards');
            const shardMap = {};
            shardsRes.rows.forEach(s => {
                // If using dbManager logic:
                // We might need to decrypt or just use what we have. 
                // Assuming simple schema for now as per `storageManager.js`
                shardMap[s.id] = s.refresh_token; // Wait, we need access tokens.
            });
            
            // To be secure, we should probably generate fresh short-lived links or 
            // give the client the access tokens (if trusted app). 
            // For this project stage, we'll try to rely on storageManager to get tokens.
            
            // ACTUALLY: storageManager has `getAllActiveStorageShards` but it returns clients?
            // Let's reuse `storageManager` logic if possible or just fetch raw.
            // Since `storageManager` handles token refresh, we should ask it for tokens.
            // But we don't have a batch method. 
            
            // Workaround: We will authorize the client to download by returning the list of { url, headers } ?
            // No, Dropbox API needs token.
            // Let's just return the list of chunks with Shard ID. 
            // The Client will have to ask "Get Token for Shard X" or we include it here. 
            
            // Let's include tokens here.
             const chunksWithTokens = [];
             
             // Optimize: Group by shard_id
             const chunksByShard = {};
             resChunks.rows.forEach(c => {
                 if(!chunksByShard[c.shard_id]) chunksByShard[c.shard_id] = [];
                 chunksByShard[c.shard_id].push(c);
             });
             
             for (const [sId, chunks] of Object.entries(chunksByShard)) {
                 // Get fresh token for this shard
                 // usage of internal function or similar
                 // We'll use storageManager.getFittestStorageAccount logic but forcing a shard ID? 
                 // It doesn't support that.
                 
                 // manual refresh logic (simplified):
                 const sMetaRes = await client.query('SELECT * FROM storage_shards WHERE id=$1', [sId]);
                 const sMeta = sMetaRes.rows[0];
                 if(sMeta) {
                     // We need a way to get a valid token.
                     // For now, let's assume the token in DB is valid or the client deals with it?
                     // No, tokens expire. 
                     // We must create a new helper in storageManager or duplicate logic.
                     
                     // Let's use the `storageManager` to Refresh token if needed
                     // We'll require `storageManager` to export a `getAccessTokenForShard(id)`
                     const token = await storageManager.getAccessTokenForShard(sId); 
                     
                     chunks.forEach(c => {
                         chunksWithTokens.push({
                             index: c.chunk_index,
                             path: c.dropbox_path,
                             token: token
                         });
                     });
                 }
             }
             
             chunksWithTokens.sort((a,b) => a.index - b.index);
             res.json({ chunks: chunksWithTokens });
        });
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
