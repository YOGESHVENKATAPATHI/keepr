const dbManager = require('./dbManager');
const storageManager = require('./storageManager');

let isRunning = false;

// Config
const BATCH_SIZE = 50; // Process 50 rows per cycle per DB (each row contains ~1000 paths)
const INTERVAL_MS = 1000 * 30; // Run every 30 seconds

async function startDeletionWorker() {
    console.log('[DeletionWorker] Starting background worker...');
    setInterval(processAllQueues, INTERVAL_MS);
    // Also run immediately on start nicely
    setTimeout(processAllQueues, 5000);
}

async function processAllQueues() {
    if (isRunning) {
        console.log('[DeletionWorker] Previous cycle still running, skipping.');
        return;
    }
    isRunning = true;
    console.log('[DeletionWorker] Cycle started.');

    let connections = [];
    try {
        connections = await dbManager.getAllWorkerDBs();
        
        // Process each DB sequentially or in parallel? Parallel is fine.
        await Promise.all(connections.map(processDB));

    } catch (e) {
        console.error('[DeletionWorker] Cycle error:', e);
    } finally {
        // CLEANUP CONNECTIONS
        for (const conn of connections) {
            try {
                await conn.client.end();
            } catch (e) {
                // ignore close errors
            }
        }
        isRunning = false;
        console.log('[DeletionWorker] Cycle finished.');
    }
}

async function processDB({ id, client }) {
    try {
        // 1. Lock rows to process (skip locked prevents conflicts if we ran multiple workers)
        // Table: deletion_queue(id, shard_id, paths::text[], status, retries)
        
        // Ensure table exists just in case (though API should have created it)
        // but worker might run on a fresh DB shard added manually? Defensively check?
        // No, assume created by API usage. If not, catching error is fine.

        const res = await client.query(`
            SELECT id, shard_id, paths, retries 
            FROM deletion_queue 
            WHERE status = 'pending' 
            ORDER BY id ASC 
            LIMIT $1 
            FOR UPDATE SKIP LOCKED
        `, [BATCH_SIZE]);

        if (res.rows.length === 0) return;

        console.log(`[DeletionWorker][DB:${id}] Processing ${res.rows.length} queue items...`);

        for (const row of res.rows) {
            await processQueueItem(client, row);
        }

    } catch (e) {
        if (e.code === '42P01') {
            // Table doesn't exist yet, which is expected on fresh systems
            // console.log(`[DeletionWorker][DB:${id}] No deletion_queue table yet.`);
        } else {
            console.error(`[DeletionWorker][DB:${id}] Error processing:`, e.message);
        }
    }
}

async function processQueueItem(client, row) {
    const { id, shard_id, paths, retries } = row;
    
    try {
        // Mark as processing (optional, but helpful for debugging)
        // await client.query('UPDATE deletion_queue SET status=$1 WHERE id=$2', ['processing', id]);
        
        if (!paths || paths.length === 0) {
            await client.query('DELETE FROM deletion_queue WHERE id=$1', [id]);
            return;
        }

        // Call Storage Manager (It handles batch logic internally if needed, 
        // but here 'paths' is likely ~1000 items, which matches the delete_batch limit)
        await storageManager.deletePathsFromShard(shard_id, paths);

        // Success: Delete from queue
        await client.query('DELETE FROM deletion_queue WHERE id=$1', [id]);
        console.log(`[DeletionWorker] Completed item ${id} (Shard ${shard_id}, ${paths.length} files)`);

    } catch (e) {
        console.error(`[DeletionWorker] Item ${id} failed:`, e.message);
        // Increment retry, delete if too many?
        if (retries >= 5) {
             console.error(`[DeletionWorker] Item ${id} failed 5 times. Removing to unblock queue (Possible orphan/permission issue).`);
             await client.query('DELETE FROM deletion_queue WHERE id=$1', [id]);
        } else {
             // Backoff could be implemented by 'last_attempt' column, but simple retry count is okay
             await client.query('UPDATE deletion_queue SET status=$1, retries=retries+1 WHERE id=$2', ['pending', id]);
        }
    }
}

module.exports = {
    startDeletionWorker,
    processAllQueues // exported for manual triggering if needed
};
