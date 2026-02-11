
const { Client } = require('pg');
require('dotenv').config();
const { MASTER_DB_URL } = process.env;

(async()=>{ 
    console.log("Connecting to Master DB...");
    const masterClient = new Client({
        connectionString: MASTER_DB_URL, 
        ssl: {rejectUnauthorized: false}
    });
    
    try {
        await masterClient.connect();
        console.log("Master connected.");
        
        // Find Shard 2
        const res = await masterClient.query("SELECT connection_string FROM db_shards WHERE id = 2");
        if (res.rows.length === 0) {
            console.log("Shard 2 not found in db_shards");
            return;
        }
        
        const shardUrl = res.rows[0].connection_string;
        console.log("Found Shard 2 URL. Connecting...");
        await masterClient.end();
        
        // Connect to Shard 2
        const shardClient = new Client({
            connectionString: shardUrl,
            ssl: {rejectUnauthorized: false}
        });
        await shardClient.connect();
        
        console.log("Connected to Shard 2.");
        
        // Inspect Table Structure
        console.log("--- Colonnes ---");
        const cols = await shardClient.query("SELECT column_name, data_type, is_identity, column_default FROM information_schema.columns WHERE table_name = 'file_chunks'");
        console.table(cols.rows);
        
        // Inspect Constraints
        console.log("--- PK Constraint ---");
        const pk = await shardClient.query(`
            SELECT
                tc.constraint_name, 
                tc.table_name, 
                kcu.column_name
            FROM 
                information_schema.table_constraints AS tc 
                JOIN information_schema.key_column_usage AS kcu
                  ON tc.constraint_name = kcu.constraint_name
            WHERE tc.constraint_type = 'PRIMARY KEY' AND tc.table_name = 'file_chunks';
        `);
        console.table(pk.rows);
        
        await shardClient.end();
        
    } catch(e) {
        console.error(e);
        if (masterClient._connected) masterClient.end();
    }
})();
