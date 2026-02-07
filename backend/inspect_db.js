
const { Client } = require('pg');
const { MASTER_DB_URL } = require('./dbManager');

(async()=>{ 
    try {
        const client = new Client({
            connectionString: MASTER_DB_URL, 
            ssl: {rejectUnauthorized: false}
        }); 
        await client.connect(); 
        const res = await client.query("SELECT column_name, is_nullable, data_type FROM information_schema.columns WHERE table_name = 'file_chunks'"); 
        console.table(res.rows); 
        await client.end(); 
    } catch(e) {
        console.error(e);
    }
})();
