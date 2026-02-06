# Keepr System Architecture

## Double Clustering Strategy

### 1. Database Clustering (Neon)

**Master Registry:**

- Defines the topology of the system.
- Table `db_shards`: Contains connection strings for all Worker DBs.
- Logic: `dbManager.getFittestDB()` queries this registry to find the worker with `current_usage < max_capacity` and returns a direct client connection to that worker.

### 2. Storage Clustering (Dropbox)

**Storage Registry:**

- Table `storage_shards`: Contains OAuth tokens for multiple Dropbox accounts.
- Logic: `storageManager.getFittestStorageAccount()` queries the registry for the account with the most free space.

## Setup Instructions

### Backend

1. Navigate to `backend/`.
2. Run `npm install`.
3. Create a `.env` file (optional, defaults are in code for demo).
4. Run `node index.js`.
   - On first run, it will automatically connect to the Main DB and create `db_shards` and `storage_shards` tables if they don't exist.

### Frontend (Flutter)

1. Navigate to `frontend/`.
2. Run `flutter pub get`.
3. Run `flutter run -d chrome` (or windows/android).

## Key Features Implemented

- **Glassmorphism UI**: See `lib/theme/keepr_theme.dart`.
- **Folder Upload**: Recursive walker and chunked upload logic in `lib/services/folder_upload_service.dart`.
- **Auth**: OTP logic using Nodemailer in `backend/auth.js`.
