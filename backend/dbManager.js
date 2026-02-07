require('dotenv').config();
const { Client } = require('pg');
const dns = require('dns');
const { promisify } = require('util');
const resolve4 = promisify(dns.resolve4);

// Set public DNS servers to bypass potential system DNS issues
try {
    dns.setServers(['8.8.8.8', '1.1.1.1']);
} catch (e) {
    console.warn('Failed to set custom DNS servers:', e.message);
}

// MASTER REGISTRY CONNECTION STRING
// Using environment variable for security and easier editing
const MASTER_DB_URL = process.env.MASTER_DB_URL;

// Helpers removed to simplify connection logic and rely on pg client


async function tryConnectWithRetries(connString, maxAttempts = 5) {
    let attempt = 0;
    while (attempt < maxAttempts) {
        attempt++;
        
        // Manual DNS Resolution Strategy
        let targetConnString = connString;
        let sniServerName = undefined;

        try {
            // Parse URL to check hostname
            // connString might be a valid URI (postgres://...)
            if (connString.startsWith('postgres')) {
                const u = new URL(connString);
                
                // CRITICAL: Remove sslmode params to prevent 'pg' from enforcing 'verify-full' 
                // against the IP address, which causes hostname mismatch errors.
                u.searchParams.delete('sslmode');
                u.searchParams.delete('ssl');

                // Check if hostname is domain-like (not an IP) and not localhost
                if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(u.hostname) && u.hostname !== 'localhost') {
                    // Manually resolve using the custom DNS servers
                    const ips = await resolve4(u.hostname);
                    if (ips && ips.length > 0) {
                        sniServerName = u.hostname; // Save original host for SNI
                        console.log(`[DB] Resolved ${u.hostname} -> ${ips[0]}`);
                        u.hostname = ips[0]; // Replace with resolved IP
                    }
                }
                targetConnString = u.toString();
            }
        } catch (dnsErr) {
            console.warn('Manual DNS resolution skipped:', dnsErr.message);
        }

        // Use explicit SSL configuration for Neon consistency
        // If we replaced host with IP, we MUST provide servername for SNI
        const clientConfig = { 
            connectionString: targetConnString,
            ssl: { 
                rejectUnauthorized: false,
                servername: sniServerName,
                // BYPASS HOSTNAME VALIDATION manually.
                // Since we connect to an IP (98.x.x.x) but the cert is for *.neon.tech,
                // default validation fails. We trust the connection because we resolved it correctly 
                // and 'rejectUnauthorized: false' handles the CA trust level for this context.
                checkServerIdentity: () => undefined 
            }
        };
        
        // Debug connection details
        // console.log(`[DB-DEBUG] Connecting to: ${targetConnString} (SNI: ${sniServerName})`);

        const client = new Client(clientConfig);

        try {
            await client.connect();
            return client; // connected
        } catch (err) {
            if (err.code === '28P01') {
                console.error('Authentication failed when connecting to DB.');
                throw err;
            }

            console.warn(`[DB] Connection attempt ${attempt}/${maxAttempts} failed: ${err.message}`);
            if (client) {
                try { await client.end(); } catch (e) {}
            }
            
            if (attempt < maxAttempts) {
                await new Promise(r => setTimeout(r, Math.pow(2, attempt - 1) * 1000));
            }
        }
    }
    throw new Error(`Exceeded connection retry attempts for DB`);
}

async function initMasterRegistry() {
    console.log("Attempting to connect to Master DB...");
    // Mask password in logs
    const maskedUrl = MASTER_DB_URL ? MASTER_DB_URL.replace(/:([^:@]+)@/, ':****@') : 'undefined';
    console.log(`Connection String: ${maskedUrl}`);

    let client = null;
    try {
        client = await tryConnectWithRetries(MASTER_DB_URL, 5);
        console.log("Connected to Master DB successfully.");

        // Table for Database Shards
        await client.query(`
            CREATE TABLE IF NOT EXISTS db_shards (
                id SERIAL PRIMARY KEY,
                connection_string TEXT NOT NULL,
                current_usage_mb NUMERIC DEFAULT 0,
                max_capacity_mb NUMERIC DEFAULT 500,
                is_active BOOLEAN DEFAULT TRUE,
                nickname VARCHAR(255)
            );
        `);

        // Table for Storage (Dropbox) Shards
        await client.query(`
            CREATE TABLE IF NOT EXISTS storage_shards (
                id SERIAL PRIMARY KEY,
                refresh_token TEXT NOT NULL,
                app_key TEXT NOT NULL,
                app_secret TEXT NOT NULL,
                current_usage_mb NUMERIC DEFAULT 0,
                max_capacity_mb NUMERIC DEFAULT 2048, -- 2GB Free Dropbox
                is_active BOOLEAN DEFAULT TRUE
            );
        `);

        console.log("Master Registry tables checked/created.");
    } catch (err) {
        console.error("Error initializing Master Registry:", err);
    } finally {
        if (client) await client.end();
    }
}

/**
 * Connects to the Master Registry, finds the least used active Worker DB,
 * and returns a connected Client to that Worker DB.
 */
async function getFittestDB() {
    let masterClient = null;
    try {
        // Connect to Master to get shard list
        masterClient = await tryConnectWithRetries(MASTER_DB_URL, 3);

        const res = await masterClient.query(`
            SELECT id, connection_string 
            FROM db_shards 
            WHERE is_active = TRUE 
            ORDER BY current_usage_mb ASC;
        `);

        // Close master connection as we don't need it anymore
        // (Assuming we want to connect to a worker, not proxy via master)
        await masterClient.end(); 
        masterClient = null;

        const shards = res.rows;
        
        if (shards.length === 0) {
            console.error("No shards registered in Master DB.");
            throw new Error("No available database shards to handle request.");
        }

        // Try to connect to shards in order of preference (least usage)
        for (const shard of shards) {
            try {
                const workerClient = await tryConnectWithRetries(shard.connection_string, 2);
                console.log(`[DB] Connected to Worker DB (shard id=${shard.id})`);
                // Attach shard info to client for usage tracking
                workerClient._shardId = shard.id;
                workerClient._connectionString = shard.connection_string;
                return workerClient;
            } catch (e) {
                console.warn(`[DB] Failed to connect to shard ${shard.id}, trying next...`);
            }
        }
        
        throw new Error("All database shards are unreachable.");

    } catch (err) {
        if (masterClient) {
            try { await masterClient.end(); } catch(e) {}
        }
        console.error("Error in getFittestDB:", err);
        throw err;
    }
}

/**
 * Connects to ALL active database shards (and Master as fallback/primary if needed).
 * Used for aggregating data across shards (scattering gathering).
 */
async function getAllWorkerDBs() {
    const clients = [];
    let masterClient = null;
    
    try {
        masterClient = await tryConnectWithRetries(MASTER_DB_URL, 3);
        const res = await masterClient.query(`
            SELECT id, connection_string, nickname
            FROM db_shards 
            WHERE is_active = TRUE;
        `);
        await masterClient.end();
        masterClient = null;

        const shards = res.rows;
        
        // 1. Uniquify connection strings (include Master if not in shards to be safe?)
        // For now, trust the shards table.
        
        const promises = shards.map(async (shard) => {
            try {
                const c = await tryConnectWithRetries(shard.connection_string, 2);
                console.log(`[DB] Connected to shard ${shard.id} (${shard.nickname || 'unnamed'})`);
                return { id: shard.id, client: c, isMaster: false };
            } catch (e) {
                console.warn(`[DB] Failed to connect to shard ${shard.id}: ${e.message}`);
                return null;
            }
        });

        const results = await Promise.all(promises);
        results.forEach(r => {
            if (r) clients.push(r);
        });

    } catch (e) {
        console.error("Failed to fetch shards for broadcast:", e);
        if (masterClient) try { await masterClient.end(); } catch (_) {}
    }

    if (clients.length === 0) {
        console.warn("[DB] No worker shards available.");
    }

    return clients;
}

/**
 * Updates the usage stats for a specific shard (simplified estimation)
 */
async function updateShardUsage(connectionString, sizeDeltaMB) {
    if (!connectionString) return;
    const masterClient = new Client({ connectionString: MASTER_DB_URL });
    try {
        // Must use tryConnect logic if simple Client fails with SSL, but simplified here for generic helper
        // Re-using tryConnectWithRetries logic would be better but circular dep risk?
        // No, we are in dbManager.
        
        // We really should use tryConnectWithRetries for the master client too
        // But for update usage (fire and forget), we can implement a lighter version or just use the exported tryConnect
    } catch (e) {/* */}

    // Use proper connection
    let client = null;
    try {
        client = await tryConnectWithRetries(MASTER_DB_URL, 2);
        await client.query(`
            UPDATE db_shards 
            SET current_usage_mb = current_usage_mb + $1 
            WHERE connection_string = $2
        `, [sizeDeltaMB, connectionString]);
    } catch (err) {
        console.error("Failed to update shard usage:", err);
    } finally {
        if (client) await client.end();
    }
}

async function updateStorageShardUsage(shardId, sizeDeltaMB) {
    let client = null;
    try {
        client = await tryConnectWithRetries(MASTER_DB_URL, 2);
        await client.query(`
            UPDATE storage_shards 
            SET current_usage_mb = current_usage_mb + $1 
            WHERE id = $2
        `, [sizeDeltaMB, shardId]);
    } catch (err) {
        console.error("Failed to update storage shard usage:", err);
    } finally {
        if (client) await client.end();
    }
}

async function getAllActiveStorageShards() {
    let client = null;
    try {
        client = await tryConnectWithRetries(MASTER_DB_URL);
        const res = await client.query(`
            SELECT * FROM storage_shards 
            WHERE is_active = TRUE 
              AND current_usage_mb < max_capacity_mb
            ORDER BY current_usage_mb ASC
        `);
        return res.rows;
    } catch (e) {
        console.error("Failed to get storage shards:", e);
        return [];
    } finally {
        if (client) await client.end();
    }
}

module.exports = {
    initMasterRegistry,
    getFittestDB,
    getAllWorkerDBs,
    getAllActiveStorageShards,
    updateShardUsage,
    updateStorageShardUsage,
    tryConnect: tryConnectWithRetries, // Export as generic helper
    MASTER_DB_URL
};
