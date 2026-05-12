const { MASTER_DB_URL, tryConnect } = require('./dbManager');
const fetch = require('node-fetch');

const DROPBOX_MASTER_DB_URL =
    process.env.DROPBOX_MASTER_DB_URL || process.env.EXTRA_MASTER_DB_URL || '';

// Token Cache to bypass 100ms OAuth handshake overhead (valid for 3.5 hours)
const accessTokenCache = new Map(); // key -> { token, expiresAt }
const CACHE_TTL_MS = 3.5 * 60 * 60 * 1000;

async function getCachedToken(key, refreshFn) {
    const now = Date.now();
    const cached = accessTokenCache.get(key);
    if (cached && cached.expiresAt > now) {
        return cached.token;
    }
    const token = await refreshFn();
    accessTokenCache.set(key, { token, expiresAt: now + CACHE_TTL_MS });
    return token;
}

// Helper to get live space usage from Dropbox
async function getLiveSpaceUsage(accessToken) {
    const url = 'https://api.dropboxapi.com/2/users/get_space_usage';
    const response = await fetch(url, {
        method: 'POST',
        headers: {
            'Authorization': `Bearer ${accessToken}`,
            'Content-Type': 'application/json'
        },
        body: 'null'
    });

    if (!response.ok) {
        const text = await response.text();
        throw new Error(`Dropbox API error (get_space_usage): ${text}`);
    }

    const data = await response.json();
    return {
        used: data.used,
        allocated: data.allocation.allocated
    };
}

async function getFittestStorageAccount(requiredSizeMb = 0) {
    let masterClient = null;
    try {
        masterClient = await tryConnect(MASTER_DB_URL);
        
        // 0. Calculate Reserved Space (Pending Chunks) to avoid over-allocation
        let pendingMap = {};
        try {
            const pendingRes = await masterClient.query(`
                SELECT shard_id, SUM(size_mb) as pending_mb 
                FROM file_chunks 
                WHERE status = 'pending' 
                GROUP BY shard_id
            `);
            pendingRes.rows.forEach(r => pendingMap[r.shard_id] = parseFloat(r.pending_mb));
        } catch (e) {
            console.warn('[Storage] Skipping pending check (table missing?):', e.message);
        }

        // O(1) Optimization: Let the DB filter and sort accounts with enough estimated free space
        const res = await masterClient.query(`
            SELECT *
            FROM storage_shards 
            WHERE is_active = TRUE 
              AND (max_capacity_mb - current_usage_mb) >= $1
            ORDER BY current_usage_mb ASC
            LIMIT 5;
        `, [requiredSizeMb]);

        // Live Validation Loop - Should break on the FIRST successful account (O(1) instead of O(N))
        for (const account of res.rows) {
            try {
                // 1. Get Token (Cached)
                const cacheKey = `shard_${account.id}`;
                const accessToken = await getCachedToken(cacheKey, () => refreshAccessToken(account.refresh_token, account.app_key, account.app_secret));
                
                // 2. Check Live Usage (Only for top candidate)
                const usageData = await getLiveSpaceUsage(accessToken);
                const usedMb = usageData.used / (1024 * 1024);
                const allocatedMb = usageData.allocated / (1024 * 1024);
                
                // Apply pending reservation
                const pendingMb = pendingMap[account.id] || 0;
                const effectiveUsedMb = usedMb + pendingMb;
                const freeMb = allocatedMb - effectiveUsedMb;

                // 3. Update DB with REAL usage
                await masterClient.query(
                    'UPDATE storage_shards SET current_usage_mb = $1 WHERE id = $2',
                    [usedMb, account.id]
                );

                // 4. Return FIRST eligible candidate immediately
                if (freeMb >= requiredSizeMb) {
                    return {
                        access_token: accessToken,
                        shard_id: account.id
                    };
                } 
            } catch (err) {
                console.warn(`[Storage] Error checking shard ${account.id}, skipping to next:`, err.message);
            }
        }
        
        throw new Error("All top candidate accounts failed live check or are full.");

    } catch (err) {
        console.error("Error in getFittestStorageAccount:", err);
        throw err;
    } finally {
        if(masterClient) await masterClient.end();
    }
}

async function getFittestStorageAccountForNotes(requiredSizeMb = 0) {
    const primary = await getAccountsFromStorageShards(requiredSizeMb);
    if (primary) return primary;

    const external = await getAccountsFromExternalRegistry(requiredSizeMb);
    if (external) return external;

    throw new Error('No eligible storage account found in primary or external registry.');
}

async function getAccountsFromStorageShards(requiredSizeMb = 0) {
    let masterClient = null;
    try {
        masterClient = await tryConnect(MASTER_DB_URL);
        const res = await masterClient.query(`
            SELECT *
            FROM storage_shards
            WHERE is_active = TRUE AND (max_capacity_mb - current_usage_mb) >= $1
            ORDER BY current_usage_mb ASC
            LIMIT 5;
        `, [requiredSizeMb]);

        for (const account of res.rows) {
            try {
                const cacheKey = `shard_${account.id}`;
                const accessToken = await getCachedToken(cacheKey, () => refreshAccessToken(account.refresh_token, account.app_key, account.app_secret));
                const usageData = await getLiveSpaceUsage(accessToken);
                const usedMb = usageData.used / (1024 * 1024);
                const allocatedMb = usageData.allocated / (1024 * 1024);
                const freeMb = allocatedMb - usedMb;

                await masterClient.query('UPDATE storage_shards SET current_usage_mb = $1 WHERE id = $2', [usedMb, account.id]);

                if (freeMb >= requiredSizeMb) {
                    return {
                        access_token: accessToken,
                        shard_id: account.id,
                        shard_ref: String(account.id),
                        storage_source: 'storage_shards',
                        freeMb
                    };
                }
            } catch (e) {
                console.warn(`[Storage] Primary shard ${account.id} check failed: ${e.message}`);
            }
        }
        return null;
    } catch (e) {
        console.warn('[Storage] Primary registry check failed:', e.message);
        return null;
    } finally {
        if (masterClient) {
            try { await masterClient.end(); } catch (_) {}
        }
    }
}

async function getAccountsFromExternalRegistry(requiredSizeMb = 0) {
    if (!DROPBOX_MASTER_DB_URL) return null;

    let client = null;
    try {
        client = await tryConnect(DROPBOX_MASTER_DB_URL);
        const res = await client.query(`
            SELECT
                id,
                app_key,
                app_secret,
                refresh_token,
                access_token,
                account_id,
                uid,
                scope,
                app_name
            FROM dropbox_app_credentials
            ORDER BY id ASC;
        `);

        // O(1) optimization for external registry too (we cannot natively filter max_capacity via simple SQL if not tracked, but we can cache and break early)
        for (const account of res.rows) {
            try {
                const cacheKey = `ext_${account.id}`;
                const accessToken = await getCachedToken(cacheKey, () => refreshAccessToken(account.refresh_token, account.app_key, account.app_secret));
                const usageData = await getLiveSpaceUsage(accessToken);
                const usedMb = usageData.used / (1024 * 1024);
                const allocatedMb = usageData.allocated / (1024 * 1024);
                const freeMb = allocatedMb - usedMb;

                if (freeMb >= requiredSizeMb) {
                    return {
                        access_token: accessToken,
                        shard_id: account.id,
                        shard_ref: String(account.id),
                        storage_source: 'dropbox_app_credentials',
                        account_id: account.account_id || null,
                        uid: account.uid || null,
                        scope: account.scope || null,
                        app_name: account.app_name || null,
                        freeMb
                    };
                }
            } catch (e) {
                console.warn(`[Storage] External credential ${account.id} check failed: ${e.message}`);
            }
        }

        return null;
    } catch (e) {
        console.warn('[Storage] External registry check failed:', e.message);
        return null;
    } finally {
        if (client) {
            try { await client.end(); } catch (_) {}
        }
    }
}

async function refreshAccessToken(refreshToken, appKey, appSecret) {
    const url = 'https://api.dropbox.com/oauth2/token';
    const params = new URLSearchParams();
    params.append('grant_type', 'refresh_token');
    params.append('refresh_token', refreshToken);
    params.append('client_id', appKey);
    params.append('client_secret', appSecret);

    const response = await fetch(url, {
        method: 'POST',
        headers: {
            'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: params
    });

    if (!response.ok) {
        const err = await response.text();
        throw new Error(`Failed to refresh Dropbox token: ${err}`);
    }

    const data = await response.json();
    return data.access_token;
}

async function startUploadSession(dbx, fileSize) {
    // This is a placeholder for the chunked upload session start
    // In production this connects to Dropbox API
    // const response = await dbx.filesUploadSessionStart({ close: false, contents: '' });
    // return response.result.session_id;
    return "mock_session_id";
}




async function deletePathsFromShard(shardId, chunkPaths) {
    if (!chunkPaths || chunkPaths.length === 0) return;
    
    // get token
    const token = await getAccessTokenForShard(shardId);
    
    // API limitation: 1000 items per batch
    const CHUNK_SIZE = 1000;
    for (let i = 0; i < chunkPaths.length; i += CHUNK_SIZE) {
        // Prepare entries: { "path": "/..." }
        const entries = chunkPaths.slice(i, i + CHUNK_SIZE).map(p => ({ "path": p }));
        
        try {
            console.log(`[Storage] Shard ${shardId} deleting batch of ${entries.length} items...`);
            const response = await fetch('https://api.dropboxapi.com/2/files/delete_batch', {
                method: 'POST',
                headers: {
                    'Authorization': `Bearer ${token}`,
                    'Content-Type': 'application/json'
                },
                body: JSON.stringify({ entries })
            });

            if (!response.ok) {
                 const txt = await response.text();
                 console.error(`[Storage] Shard ${shardId} delete_batch failed:`, txt);
            } else {
                 const d = await response.json();
                 
                 if (d['.tag'] === 'async_job_id') {
                      const jobId = d.async_job_id;
                      console.log(`[Storage] Shard ${shardId} deletion queued (Job: ${jobId}). Waiting for completion...`);
                      await waitForDeleteJob(token, jobId, shardId);
                 } else if (d['.tag'] === 'complete') {
                      console.log(`[Storage] Shard ${shardId} deletion completed immediately.`);
                 } else {
                      console.log(`[Storage] Shard ${shardId} unknown response tag: ${d['.tag']}`);
                 }
            }
        } catch(e) {
            console.error(`[Storage] Shard ${shardId} delete exception`, e);
        }
    }
}

async function waitForDeleteJob(token, jobId, shardId) {
    let attempts = 0;
    while(attempts < 60) { // Timeout after 60s approx
        attempts++;
        await new Promise(r => setTimeout(r, 1000));
        
        try {
            const res = await fetch('https://api.dropboxapi.com/2/files/delete_batch/check', {
                method: 'POST',
                headers: { 'Authorization': `Bearer ${token}`, 'Content-Type': 'application/json' },
                body: JSON.stringify({ async_job_id: jobId })
            });
            
            if (!res.ok) {
                 console.warn(`[Storage] Shard ${shardId} check-job failed:`, await res.text());
                 return; 
            }
            
            const status = await res.json();
            if (status['.tag'] === 'complete') {
                console.log(`[Storage] Shard ${shardId} Job ${jobId} finished successfully.`);
                return;
            } else if (status['.tag'] === 'failed') {
                console.error(`[Storage] Shard ${shardId} Job ${jobId} reported FAILURE.`, status);
                return;
            }
            // else 'in_progress' -> loop continue
        } catch(e) {
            console.error(`[Storage] Shard ${shardId} check-job exception`, e);
            // don't break immediately on network blip
        }
    }
    console.warn(`[Storage] Shard ${shardId} Job ${jobId} timed out or stuck.`);
}

async function getAccessTokenForShard(shardId) {
    return getAccessTokenForReference({
        storageSource: 'storage_shards',
        shardRef: String(shardId)
    });
}

async function getAccessTokenForReference({ storageSource, shardRef }) {
    const cacheKey = `ref_${storageSource}_${shardRef}`;

    if (storageSource === 'dropbox_app_credentials') {
        if (!DROPBOX_MASTER_DB_URL) throw new Error('DROPBOX_MASTER_DB_URL is not configured');

        let externalClient = null;
        try {
            externalClient = await tryConnect(DROPBOX_MASTER_DB_URL);
            const res = await externalClient.query(
                'SELECT app_key, app_secret, refresh_token FROM dropbox_app_credentials WHERE id = $1',
                [parseInt(shardRef, 10)]
            );
            if (res.rows.length === 0) throw new Error(`External credential ${shardRef} not found`);

            const account = res.rows[0];
            return await getCachedToken(cacheKey, () => refreshAccessToken(account.refresh_token, account.app_key, account.app_secret));
        } finally {
            if (externalClient) {
                try { await externalClient.end(); } catch (_) {}
            }
        }
    }

    let masterClient = null;
    try {
        masterClient = await tryConnect(MASTER_DB_URL);
        const shardId = parseInt(shardRef, 10);
        const res = await masterClient.query('SELECT * FROM storage_shards WHERE id = $1', [shardId]);
        if (res.rows.length === 0) throw new Error(`Shard ${shardId} not found`);
        
        const account = res.rows[0];
        return await getCachedToken(cacheKey, () => refreshAccessToken(account.refresh_token, account.app_key, account.app_secret));
    } finally {
        if (masterClient) await masterClient.end();
    }
}

async function getTotalStorageStats() {
    let totalAllocated = 0;
    let totalUsed = 0;
    
    // We'll gather all active accounts from both databases
    const allAccounts = [];

    // 1. From storage_shards (Master DB)
    let masterClient = null;
    try {
        masterClient = await tryConnect(MASTER_DB_URL);
        const res = await masterClient.query('SELECT id, refresh_token, app_key, app_secret FROM storage_shards WHERE is_active = TRUE');
        allAccounts.push(...res.rows.map(r => ({ ...r, source: 'master' })));
    } catch (e) {
        console.error('[Storage Stats] Error fetching from master db:', e.message);
    } finally {
        if (masterClient) try { await masterClient.end(); } catch(_) {}
    }

    // 2. From dropbox_app_credentials (Neon DB)
    const neonDbUrl = process.env.DROPBOX_NEON_DB || process.env.DROPBOX_MASTER_DB_URL;
    if (neonDbUrl) {
        let neonClient = null;
        try {
            neonClient = await tryConnect(neonDbUrl);
            const res = await neonClient.query('SELECT id, refresh_token, app_key, app_secret FROM dropbox_app_credentials');
            allAccounts.push(...res.rows.map(r => ({ ...r, source: 'neon' })));
        } catch (e) {
            console.error('[Storage Stats] Error fetching from neon db:', e.message);
        } finally {
            if (neonClient) try { await neonClient.end(); } catch(_) {}
        }
    }

    // Process in chunks of 10 to avoid rate limiting
    const CHUNK_SIZE = 10;
    for (let i = 0; i < allAccounts.length; i += CHUNK_SIZE) {
        const chunk = allAccounts.slice(i, i + CHUNK_SIZE);
        const promises = chunk.map(async (account) => {
            try {
                const accessToken = await refreshAccessToken(account.refresh_token, account.app_key, account.app_secret);
                const usageData = await getLiveSpaceUsage(accessToken);
                return { allocated: usageData.allocated, used: usageData.used };
            } catch (err) {
                console.error(`[Storage Stats] Error fetching usage for account ${account.id} (${account.source}):`, err.message);
                return { allocated: 0, used: 0 };
            }
        });

        const results = await Promise.all(promises);
        for (const res of results) {
            totalAllocated += res.allocated;
            totalUsed += res.used;
        }
    }

    return {
        usedBytes: totalUsed,
        allocatedBytes: totalAllocated
    };
}

module.exports = {
    getFittestStorageAccount,
    getFittestStorageAccountForNotes,
    getAccessTokenForShard,
    getAccessTokenForReference,
    deletePathsFromShard,
    getTotalStorageStats
};
