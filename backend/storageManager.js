const { MASTER_DB_URL, tryConnect } = require('./dbManager');
const fetch = require('node-fetch');

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
        // Use central connection logic
        masterClient = await tryConnect(MASTER_DB_URL);
        
        console.log(`[Storage] Looking for account with ${requiredSizeMb.toFixed(2)}MB free space...`);

        // Find all active candidates to check live (ignoring DB cached usage to be fully "lively")
        const res = await masterClient.query(`
            SELECT *
            FROM storage_shards 
            WHERE is_active = TRUE
            ORDER BY id ASC;
        `);

        console.log(`[Storage] Found ${res.rows.length} active shards. Starting live checks...`);
        
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
            console.log('[Storage] Pending allocations map:', pendingMap);
        } catch (e) {
            // Table might not exist yet if no uploads started
            console.warn('[Storage] Skipping pending check (table missing?):', e.message);
        }

        let bestCandidate = null;

        // Live Validation Loop
        for (const account of res.rows) {
            try {
                // 1. Refresh Token
                const accessToken = await refreshAccessToken(account.refresh_token, account.app_key, account.app_secret);
                
                // 2. Check Live Usage
                const usageData = await getLiveSpaceUsage(accessToken);
                const usedMb = usageData.used / (1024 * 1024);
                const allocatedMb = usageData.allocated / (1024 * 1024);
                
                // Apply pending reservation
                const pendingMb = pendingMap[account.id] || 0;
                const effectiveUsedMb = usedMb + pendingMb;
                const freeMb = allocatedMb - effectiveUsedMb;

                console.log(`[Storage] Live Check Shard ${account.id}: Free=${freeMb.toFixed(2)}MB (Live Used: ${usedMb.toFixed(2)} + Pending: ${pendingMb.toFixed(2)} / Alloc: ${allocatedMb.toFixed(0)})`);

                // 3. Update DB with REAL usage (keep DB consistent with Dropbox)
                await masterClient.query(
                    'UPDATE storage_shards SET current_usage_mb = $1 WHERE id = $2',
                    [usedMb, account.id]
                );

                // 4. Check eligibility
                if (freeMb >= requiredSizeMb) {
                    // If we haven't picked one, or this one has MORE free space, pick it.
                    // (Simple strategy: Pick first fitting, or max free space? "Fittest" implies best fit or most space.)
                    // Let's pick the one with most free space to balance load? Or just first compliant?
                    // User said "check eligible accounts".
                    
                    if (!bestCandidate || freeMb > bestCandidate.freeMb) {
                         bestCandidate = {
                             access_token: accessToken,
                             shard_id: account.id,
                             freeMb: freeMb
                         };
                    }
                } 

            } catch (err) {
                console.error(`[Storage] Error checking shard ${account.id}:`, err.message);
            }
        }
        
        if (bestCandidate) {
            console.log(`[Storage] Selected best shard id=${bestCandidate.shard_id} with ${bestCandidate.freeMb.toFixed(2)}MB free.`);
            return {
                access_token: bestCandidate.access_token,
                shard_id: bestCandidate.shard_id
            };
        }
        
        throw new Error("All active accounts failed live check or are full.");

    } catch (err) {
        console.error("Error in getFittestStorageAccount:", err);
        throw err;
    } finally {
        if(masterClient) await masterClient.end();
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
    let masterClient = null;
    try {
        masterClient = await tryConnect(MASTER_DB_URL);
        const res = await masterClient.query('SELECT * FROM storage_shards WHERE id = $1', [shardId]);
        if (res.rows.length === 0) throw new Error(`Shard ${shardId} not found`);
        
        const account = res.rows[0];
        return await refreshAccessToken(account.refresh_token, account.app_key, account.app_secret);
    } finally {
        if (masterClient) await masterClient.end();
    }
}

module.exports = {
    getFittestStorageAccount,
    getAccessTokenForShard,
    deletePathsFromShard
};
