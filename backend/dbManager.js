require('dotenv').config();
const { Client, Pool } = require('pg');
const dns = require('dns');
const { promisify } = require('util');
const resolve4 = promisify(dns.resolve4);

const DNS_CACHE_TTL_MS = 5 * 60 * 1000;
const SHARD_CACHE_TTL_MS = 30 * 1000;
const dnsCache = new Map();
const dbPools = new Map(); // Pool Cache for O(1) connection reuse
let workerShardCache = {
    expiresAt: 0,
    shards: []
};

// Set public DNS servers to bypass potential system DNS issues
try {
    dns.setServers(['8.8.8.8', '1.1.1.1']);
} catch (e) {
    console.warn('Failed to set custom DNS servers:', e.message);
}

// MASTER REGISTRY CONNECTION STRING
const MASTER_DB_URL = process.env.MASTER_DB_URL;


async function tryConnectWithRetries(connString, maxAttempts = 5) {
    let attempt = 0;
    while (attempt < maxAttempts) {
        attempt++;
        
        let targetConnString = connString;
        let sniServerName = undefined;

        try {
            if (connString.startsWith('postgres')) {
                const u = new URL(connString);
                
                u.searchParams.delete('sslmode');
                u.searchParams.delete('ssl');

                if (!/^(\d{1,3}\.){3}\d{1,3}$/.test(u.hostname) && u.hostname !== 'localhost') {
                    const now = Date.now();
                    const cached = dnsCache.get(u.hostname);

                    if (cached && cached.expiresAt > now) {
                        sniServerName = u.hostname;
                        u.hostname = cached.ip;
                    } else {
                        const ips = await resolve4(u.hostname);
                        if (ips && ips.length > 0) {
                            sniServerName = u.hostname; 
                            dnsCache.set(u.hostname, { ip: ips[0], expiresAt: now + DNS_CACHE_TTL_MS });
                            u.hostname = ips[0]; 
                        }
                    }
                }
                targetConnString = u.toString();
            }
        } catch (dnsErr) {
            console.warn('Manual DNS resolution skipped:', dnsErr.message);
        }

        try {
            // Get or Create Pool
            if (!dbPools.has(targetConnString)) {
                const poolConfig = { 
                    connectionString: targetConnString,
                    ssl: { 
                        rejectUnauthorized: false,
                        servername: sniServerName,
                        checkServerIdentity: () => undefined 
                    },
                    max: 20, // Max 20 active connections per pool
                    idleTimeoutMillis: 30000,
                    connectionTimeoutMillis: 10000,
                };
                dbPools.set(targetConnString, new Pool(poolConfig));
            }

            const pool = dbPools.get(targetConnString);
            const client = await pool.connect();
            
            // MAGIC FIX: Override .end() to securely release the connection back to the pool!
            // This prevents index.js from actually destroying the TCP connection when it calls .end()
            let released = false;
            client.end = async () => {
                if (!released) {
                    released = true;
                    client.release();
                }
            };

            return client; // connected PoolClient
        } catch (err) {
            if (err.code === '28P01') {
                console.error('Authentication failed when connecting to DB.');
                throw err;
            }

            console.warn(`[DB] Connection attempt ${attempt}/${maxAttempts} failed: ${err.message}`);
            
            if (attempt < maxAttempts) {
                await new Promise(r => setTimeout(r, Math.pow(2, attempt - 1) * 1000));
            }
        }
    }
    throw new Error(`Exceeded connection retry attempts for DB`);
}

async function fetchActiveShards(force = false) {
    const now = Date.now();
    if (!force && workerShardCache.expiresAt > now && workerShardCache.shards.length > 0) {
        return workerShardCache.shards;
    }

    let masterClient = null;
    try {
        masterClient = await tryConnectWithRetries(MASTER_DB_URL, 3);
        const res = await masterClient.query(`
            SELECT id, connection_string, nickname
            FROM db_shards
            WHERE is_active = TRUE
            ORDER BY current_usage_mb ASC;
        `);

        workerShardCache = {
            expiresAt: now + SHARD_CACHE_TTL_MS,
            shards: res.rows
        };
        return res.rows;
    } finally {
        if (masterClient) {
            try { await masterClient.end(); } catch (_) {}
        }
    }
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
    try {
        let shards = await fetchActiveShards(false);
        
        if (shards.length === 0) {
            console.error("No shards registered in Master DB.");
            throw new Error("No available database shards to handle request.");
        }

        // Try to connect to shards in order of preference (least usage)
        for (const shard of shards) {
            try {
                const workerClient = await tryConnectWithRetries(shard.connection_string, 2);
                console.log(`[DB] Connected to Worker DB (shard id=${shard.id})`);
                return workerClient;
            } catch (e) {
                console.warn(`[DB] Failed to connect to shard ${shard.id}, trying next...`);
            }
        }

        // Force-refresh shard list once and retry quickly
        shards = await fetchActiveShards(true);
        for (const shard of shards) {
            try {
                const workerClient = await tryConnectWithRetries(shard.connection_string, 1);
                console.log(`[DB] Connected to Worker DB after refresh (shard id=${shard.id})`);
                return workerClient;
            } catch (_) {
                // try next
            }
        }
        
        throw new Error("All database shards are unreachable.");

    } catch (err) {
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
    
    try {
        const shards = await fetchActiveShards(false);
        
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
    const masterClient = new Client({ connectionString: MASTER_DB_URL });
    try {
        await masterClient.connect();
        await masterClient.query(`
            UPDATE db_shards 
            SET current_usage_mb = current_usage_mb + $1 
            WHERE connection_string = $2
        `, [sizeDeltaMB, connectionString]);
    } catch (err) {
        console.error("Failed to update shard usage:", err);
    } finally {
        await masterClient.end();
    }
}

module.exports = {
    initMasterRegistry,
    getFittestDB,
    getAllWorkerDBs,
    updateShardUsage,
    tryConnect: tryConnectWithRetries, // Export as generic helper
    MASTER_DB_URL,
    fetchActiveShards
};
