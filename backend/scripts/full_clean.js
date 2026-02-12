/*
 Full clean script - WARNING: DESTRUCTIVE
 - Deletes all application records from ALL worker (Neon) DBs (NOT the master registry)
 - Deletes all file chunk objects from every configured Dropbox storage shard

 Usage:
  - Dry run (safe):    node scripts/full_clean.js
  - Execute (destructive): node scripts/full_clean.js --yes

 The script is intentionally conservative: it lists affected tables and counts first, then requires --yes to actually truncate and delete Dropbox paths.
*/

const dbManager = require('../dbManager');
const storageManager = require('../storageManager');
const argv = require('minimist')(process.argv.slice(2));

const CONFIRM_FLAG = argv.yes || argv.y || false;
const DRY_RUN = !CONFIRM_FLAG;

async function listWorkerTables(client) {
  const res = await client.query("SELECT tablename FROM pg_tables WHERE schemaname = 'public' ORDER BY tablename");
  return res.rows.map(r => r.tablename).filter(n => !n.startsWith('pg_') && !n.startsWith('sql_'));
}

async function rowCounts(client, tables) {
  const counts = {};
  for (const t of tables) {
    try {
      const r = await client.query(`SELECT COUNT(*) AS cnt FROM \"${t}\"`);
      counts[t] = parseInt(r.rows[0].cnt, 10);
    } catch (e) {
      counts[t] = `ERR: ${e.message}`;
    }
  }
  return counts;
}

async function collectChunkPathsFromAllWorkers() {
  const clients = await dbManager.getAllWorkerDBs();
  const shardMap = {}; // shardId -> Set(paths)
  for (const { id, client } of clients) {
    try {
      // Collect from file_chunks (if exists)
      try {
        const checkChunks = await client.query("SELECT to_regclass('public.file_chunks') AS r");
        if (checkChunks.rows[0].r) {
          const res = await client.query("SELECT shard_id, dropbox_path FROM file_chunks WHERE dropbox_path IS NOT NULL");
          for (const row of res.rows) {
            const sid = row.shard_id || row.shardid || 0;
            const p = row.dropbox_path;
            if (!p) continue;
            shardMap[sid] = shardMap[sid] || new Set();
            shardMap[sid].add(p);
          }
        }
      } catch (e) {
        console.warn(`[collect] shard ${id} file_chunks check failed: ${e.message}`);
      }

      // Also collect dropbox_path values from `files` table (user files)
      try {
        const checkFiles = await client.query("SELECT to_regclass('public.files') AS r");
        if (checkFiles.rows[0].r) {
          const fres = await client.query("SELECT dropbox_path FROM files WHERE dropbox_path IS NOT NULL");
          for (const row of fres.rows) {
            const p = row.dropbox_path;
            if (!p) continue;
            // We don't have shard_id for these rows; they may be distributed. Use shard 0 bucket for global deletion attempt
            const sid = 0;
            shardMap[sid] = shardMap[sid] || new Set();
            shardMap[sid].add(p);
          }
        }
      } catch (e) {
        console.warn(`[collect] shard ${id} files check failed: ${e.message}`);
      }

      // Also collect any dropbox_path from file_uploads (distributed uploads)
      try {
        const checkUploads = await client.query("SELECT to_regclass('public.file_uploads') AS r");
        if (checkUploads.rows[0].r) {
          const ures = await client.query("SELECT path FROM file_uploads WHERE path IS NOT NULL");
          for (const row of ures.rows) {
            // path here is logical app path; convert to candidate dropbox path under keepr_chunks if present
            const p = row.path;
            if (!p) continue;
            // add a candidate folder for removal (e.g. '/keepr_chunks/<fileId>') — but we keep simplest approach
            // Skip adding unless it clearly maps to a dropbox path
          }
        }
      } catch (e) {
        /* ignore */
      }

    } catch (e) {
      console.warn(`[collect] worker ${id} error: ${e.message}`);
    } finally {
      try { await client.end(); } catch(_) {}
    }
  }

  // Always attempt to delete top-level Keepr app folders (cleanup safety)
  // These are safe to try even if they don't exist in the DB paths collected.
  const appRoots = ['/keepr_chunks', '/keepr'];
  for (const root of appRoots) {
    // Mark as shard 0 (will be broadcast to all storage shards)
    shardMap[0] = shardMap[0] || new Set();
    shardMap[0].add(root);
  }

  // convert sets to arrays
  const out = {};
  for (const k of Object.keys(shardMap)) out[k] = Array.from(shardMap[k]);
  return out;
}

async function doTruncate(client, tables) {
  if (tables.length === 0) return;
  // Build safe comma-separated list (already validated)
  const tlist = tables.map(t => `\"${t}\"`).join(', ');
  // Use TRUNCATE ... RESTART IDENTITY CASCADE to clean up everything
  await client.query(`TRUNCATE TABLE ${tlist} RESTART IDENTITY CASCADE`);
}

async function main() {
  console.log('=== Keepr FULL CLEAN SCRIPT ===');
  console.log('This will REMOVE ALL application data from ALL worker DBs and DELETE stored file chunks from Dropbox.');
  console.log('Dry-run by default. Pass --yes to perform the destructive operation.');
  console.log('');

  // 1) Gather worker DBs and report tables + counts
  const workers = await dbManager.getAllWorkerDBs();
  if (!workers || workers.length === 0) {
    console.warn('No worker DBs found. Aborting.');
    return;
  }

  const summary = [];
  for (const w of workers) {
    const { id, client } = w;
    try {
      const tables = await listWorkerTables(client);
      const counts = await rowCounts(client, tables);
      summary.push({ shardId: id, tables, counts });
    } catch (e) {
      console.warn(`[report] shard ${id} error: ${e.message}`);
    } finally {
      // don't end client yet here; getAllWorkerDBs returns fresh clients which must be closed below if not used
      try { await client.end(); } catch(_) {}
    }
  }

  console.log('\nWorker DB summary:');
  for (const s of summary) {
    console.log(`- Shard ${s.shardId}: ${s.tables.length} tables`);
    for (const t of s.tables) {
      console.log(`    ${t} => ${s.counts[t]}`);
    }
  }

  // 2) Collect file chunk paths (grouped by storage shard)
  const shardPaths = await collectChunkPathsFromAllWorkers();
  console.log('\nCollected DropBox chunk paths by storage shard:');
  const shardIds = Object.keys(shardPaths);
  if (shardIds.length === 0) console.log('  (no file_chunks/dropbox paths found)');
  for (const sid of shardIds) {
    console.log(`- Storage shard ${sid}: ${shardPaths[sid].length} paths`);
  }

  if (DRY_RUN) {
    console.log('\n=== DRY RUN complete. No data was changed.');
    console.log('To perform the destructive clean, re-run with `--yes` flag.');
    return;
  }

  // 3) Confirm again (safety)
  if (!CONFIRM_FLAG) {
    console.log('\nConfirmation flag missing. Aborting.');
    return;
  }

  console.log('\nProceeding with destructive clean...');

  // 4) Delete DropBox paths per storage shard
  // If shard '0' was used to store "app root" paths, broadcast those to every configured storage shard.
  const masterClient = await dbManager.tryConnect(dbManager.MASTER_DB_URL);
  let allStorageShardIds = [];
  try {
    const sres = await masterClient.query('SELECT id FROM storage_shards WHERE is_active = TRUE');
    allStorageShardIds = sres.rows.map(r => r.id);
  } catch (e) {
    console.warn('[full_clean] failed to read storage_shards from master registry:', e.message);
  } finally {
    try { await masterClient.end(); } catch(_) {}
  }

  for (const sidKey of Object.keys(shardPaths)) {
    const sid = parseInt(sidKey, 10);
    const paths = shardPaths[sidKey];
    if (!paths || paths.length === 0) continue;

    if (sid === 0) {
      // broadcast app-root paths to all storage shards
      for (const realShardId of allStorageShardIds) {
        try {
          console.log(`[storage] deleting ${paths.length} app-root paths on shard ${realShardId} ...`);
          await storageManager.deletePathsFromShard(realShardId, paths);
          console.log(`[storage] shard ${realShardId} app-root deletion requested/completed.`);
        } catch (e) {
          console.error(`[storage] shard ${realShardId} app-root deletion FAILED: ${e.message}`);
        }
      }
      continue;
    }

    try {
      console.log(`[storage] deleting ${paths.length} items on shard ${sid} ...`);
      await storageManager.deletePathsFromShard(sid, paths);
      console.log(`[storage] shard ${sid} deletion requested/completed.`);
    } catch (e) {
      console.error(`[storage] shard ${sid} deletion FAILED: ${e.message}`);
    }
  }

  // 5) Truncate tables on each worker DB
  const workers2 = await dbManager.getAllWorkerDBs();
  for (const { id, client } of workers2) {
    try {
      const tables = await listWorkerTables(client);
      if (tables.length === 0) {
        console.log(`[truncate] shard ${id} - no tables found`);
      } else {
        console.log(`[truncate] shard ${id} - truncating ${tables.length} tables...`);
        await doTruncate(client, tables);
        console.log(`[truncate] shard ${id} - done.`);
      }
    } catch (e) {
      console.error(`[truncate] shard ${id} error: ${e.message}`);
    } finally {
      try { await client.end(); } catch(_) {}
    }
  }

  console.log('\n=== FULL CLEAN completed successfully.');
}

main().catch(err => {
  console.error('Fatal:', err);
  process.exit(1);
});