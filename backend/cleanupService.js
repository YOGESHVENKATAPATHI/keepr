const dbManager = require('./dbManager');
const storageManager = require('./storageManager');

/**
 * Performs a full system wipe:
 * 1. Collects all file paths from all worker DBs.
 * 2. Deletes those files (and app roots) from all Dropbox shards.
 * 3. Truncates all tables in all worker DBs.
 */
async function performFullWipe() {
    console.log('[Admin] Starting FULL WIPE...');
    const log = [];
    function logMsg(msg) {
        console.log(msg);
        log.push(msg);
    }

    // 1. Get all worker DB clients
    logMsg('[Admin] Connecting to worker DBs...');
    let workers = [];
    try {
        workers = await dbManager.getAllWorkerDBs();
    } catch (e) {
        logMsg(`[Admin] Failed to get worker DBs: ${e.message}`);
        // Fallback: try to connect to master and get list manually if dbManager helper fails?
        // For now, assume dbManager works.
        // If no workers, we might still want to clean storage if possible, but we need DB to know where shards are?
        // Actually, we can just list all storage shards from Master and wipe them.
    }

    // 2. Wipe Storage
    // Strategy: innovative approach for Vercel timeout limits.
    // Instead of querying DB for every file path (which might consist of millions of rows),
    // we can just delete the root folders on Dropbox: '/keepr_chunks' and '/keepr'.
    // This is much faster and guarantees cleanup.
    
    logMsg('[Admin] Wiping Storage Shards...');
    try {
        const masterClient = await dbManager.tryConnect(dbManager.MASTER_DB_URL);
        let storageShards = [];
        try {
            const res = await masterClient.query('SELECT id FROM storage_shards WHERE is_active = TRUE');
            storageShards = res.rows;
        } finally {
             await masterClient.end();
        }

        const foldersToDelete = ['/keepr_chunks', '/keepr', '/keepr_files']; // Add any other roots

        const wipePromises = storageShards.map(async (shard) => {
             try {
                // IMPORTANT: Vercel / serverless might have limited CPU/Time.
                 logMsg(`[Admin] Cleaning Shard ${shard.id}...`);
                 // storageManager.deletePathsFromShard expects an array of paths.
                 // We pass the root folders. Dropbox delete_batch can handle folders.
                 
                 // NOTE: If deletePathsFromShard does chunking (limit 1000), 3 items is fine.
                 await storageManager.deletePathsFromShard(shard.id, foldersToDelete);
                 logMsg(`[Admin] Shard ${shard.id} clean command sent.`);
                 
                 // Also ensure we re-create the root folders if the app expects them?
                 // Usually app creates them on upload. But just in case.
                 // Or we just leave them empty.
             } catch (e) {
                 logMsg(`[Admin] Failed to clean shard ${shard.id}: ${e.message}`);
             }
        });

        await Promise.all(wipePromises);

    } catch (e) {
        logMsg(`[Admin] Storage wipe error: ${e.message}`);
    }

    // 3. Wipe Databases (Workers)
    logMsg('[Admin] Wiping Worker DBs...');
    try {
        const wipeWorkerPromises = workers.map(async (w) => {
            const { id, client } = w;
            try {
                // Get tables
                const res = await client.query("SELECT tablename FROM pg_tables WHERE schemaname = 'public'");
                const tables = res.rows
                    .map(r => r.tablename)
                    .filter(t => !t.startsWith('pg_') && !t.startsWith('sql_'));

                if (tables.length > 0) {
                    const tList = tables.map(t => `"${t}"`).join(', ');
                    await client.query(`TRUNCATE TABLE ${tList} RESTART IDENTITY CASCADE`);
                    logMsg(`[Admin] Shard ${id}: Truncated ${tables.length} tables.`);
                } else {
                    logMsg(`[Admin] Shard ${id}: No tables to truncate.`);
                }
            } catch (e) {
                logMsg(`[Admin] Shard ${id} truncate failed: ${e.message}`);
            } finally {
                try { await client.end(); } catch (e) {}
            }
        });

        await Promise.all(wipeWorkerPromises);
    } catch (e) {
         logMsg(`[Admin] Worker DB wipe error: ${e.message}`);
    }

    // 4. Wipe Master Registry (App Tables Only)
    logMsg('[Admin] Checking Master DB for app data...');
    try {
        const masterClient = await dbManager.tryConnect(dbManager.MASTER_DB_URL);
        try {
            // Updated configTables to preserve critical infra
            const configTables = ['storage_shards', 'shard_registry', 'bucket_mappings']; 
            const res = await masterClient.query("SELECT tablename FROM pg_tables WHERE schemaname = 'public'");
            
            const tablesToWipe = res.rows
                .map(r => r.tablename)
                .filter(t => !t.startsWith('pg_') && !t.startsWith('sql_') && !configTables.includes(t));
            
            if (tablesToWipe.length > 0) {
                 const tList = tablesToWipe.map(t => `"${t}"`).join(', ');
                 await masterClient.query(`TRUNCATE TABLE ${tList} RESTART IDENTITY CASCADE`);
                 logMsg(`[Admin] Master: Truncated ${tablesToWipe.join(', ')}`);
            } else {
                 logMsg('[Admin] Master: No app tables to truncate.');
            }
        } finally {
            try { await masterClient.end(); } catch(e) {}
        }
    } catch (e) {
         logMsg(`[Admin] Master cleanup error: ${e.message}`);
    }

    logMsg('[Admin] Wipe Complete.');
    return log;
}

module.exports = { performFullWipe };
