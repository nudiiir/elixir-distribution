package store

import (
	"database/sql"
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/google/uuid"
	"golang.org/x/crypto/bcrypt"
	_ "modernc.org/sqlite"
)

//go:embed migrations/*.sql
var migrationsFS embed.FS

// OpenReadOnly ouvre un second pool, en lecture seule, sur le même fichier :
// les analyses lisent en parallèle du writer (WAL) sans jamais se placer
// devant une validation de vente. query_only interdit toute écriture même par
// erreur de programmation.
func OpenReadOnly(path string, conns int) (*sql.DB, error) {
	dsn := fmt.Sprintf(
		"file:%s?mode=ro&_pragma=query_only(1)&_pragma=busy_timeout(5000)",
		filepath.ToSlash(path),
	)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	if conns <= 0 {
		conns = 2
	}
	db.SetMaxOpenConns(conns)
	if err := db.Ping(); err != nil {
		return nil, err
	}
	return db, nil
}

// Open opens the SQLite database. One server process owns the file; a single
// connection serializes all access, which is ample at shop scale and removes
// every locking concern.
func Open(path string) (*sql.DB, error) {
	dsn := fmt.Sprintf(
		"file:%s?_pragma=journal_mode(WAL)&_pragma=foreign_keys(ON)&_pragma=busy_timeout(5000)&_pragma=synchronous(NORMAL)",
		filepath.ToSlash(path),
	)
	db, err := sql.Open("sqlite", dsn)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	if err := db.Ping(); err != nil {
		return nil, err
	}
	return db, nil
}

func Migrate(db *sql.DB) error {
	if _, err := db.Exec(`CREATE TABLE IF NOT EXISTS schema_migrations (
		name TEXT PRIMARY KEY, applied_at TEXT NOT NULL)`); err != nil {
		return err
	}
	entries, err := migrationsFS.ReadDir("migrations")
	if err != nil {
		return err
	}
	names := make([]string, 0, len(entries))
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".sql") {
			names = append(names, e.Name())
		}
	}
	sort.Strings(names)

	for _, name := range names {
		var done int
		if err := db.QueryRow(`SELECT COUNT(*) FROM schema_migrations WHERE name = ?`, name).Scan(&done); err != nil {
			return err
		}
		if done > 0 {
			continue
		}
		body, err := migrationsFS.ReadFile("migrations/" + name)
		if err != nil {
			return err
		}
		tx, err := db.Begin()
		if err != nil {
			return err
		}
		if _, err := tx.Exec(string(body)); err != nil {
			tx.Rollback()
			return fmt.Errorf("migration %s: %w", name, err)
		}
		if _, err := tx.Exec(`INSERT INTO schema_migrations (name, applied_at) VALUES (?, ?)`,
			name, time.Now().UTC().Format(time.RFC3339)); err != nil {
			tx.Rollback()
			return err
		}
		if err := tx.Commit(); err != nil {
			return err
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Guided restore. The API only RECORDS the wish (restore.pending next to the
// database, holding the backup file name); the swap happens here, at the next
// server start, BEFORE the database is opened — never under a live server.

const (
	pendingRestoreFile = "restore.pending"
	lastRestoreFile    = "restore.last"
)

// BackupsDir is the backups folder next to the database file.
func BackupsDir(dbPath string) string { return filepath.Join(filepath.Dir(dbPath), "backups") }

// PendingRestorePath is the marker file the API writes.
func PendingRestorePath(dbPath string) string {
	return filepath.Join(filepath.Dir(dbPath), pendingRestoreFile)
}

// ReadPendingRestore returns the backup name waiting to be restored, or "".
func ReadPendingRestore(dbPath string) string {
	b, err := os.ReadFile(PendingRestorePath(dbPath))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(b))
}

// LastRestore is what the previous startup restore did (or why it failed).
type LastRestore struct {
	Backup string `json:"backup"`
	Before string `json:"before"`
	At     string `json:"at"`
	Error  string `json:"error,omitempty"`
}

// ReadLastRestore returns the report of the last startup restore, if any.
func ReadLastRestore(dbPath string) *LastRestore {
	b, err := os.ReadFile(filepath.Join(filepath.Dir(dbPath), lastRestoreFile))
	if err != nil {
		return nil
	}
	var lr LastRestore
	if json.Unmarshal(b, &lr) != nil {
		return nil
	}
	return &lr
}

// ValidBackupName accepts a plain file name of the backups folder.
func ValidBackupName(name string) bool {
	return name != "" && filepath.Base(name) == name && !strings.ContainsAny(name, `/\:`) &&
		strings.HasSuffix(name, ".db") && !strings.HasPrefix(name, ".")
}

// ApplyPendingRestore performs a restore recorded by the API. It must run
// before Open. The current database is first saved to
// backups/before-restore-<stamp>.db (VACUUM INTO, so the WAL is included),
// then the chosen backup is copied over it. Returns the restored backup name
// ("" when nothing was pending). On error the current database is left as it
// was and the reason is written to restore.last.
func ApplyPendingRestore(dbPath string) (string, error) {
	name := ReadPendingRestore(dbPath)
	if name == "" {
		return "", nil
	}
	report := LastRestore{Backup: name, At: time.Now().UTC().Format(time.RFC3339)}
	writeReport := func() {
		b, _ := json.Marshal(report)
		os.WriteFile(filepath.Join(filepath.Dir(dbPath), lastRestoreFile), b, 0o644)
		os.Remove(PendingRestorePath(dbPath))
	}
	fail := func(err error) (string, error) {
		report.Error = err.Error()
		writeReport()
		return "", err
	}
	if !ValidBackupName(name) {
		return fail(fmt.Errorf("nom de sauvegarde invalide : %q", name))
	}
	src := filepath.Join(BackupsDir(dbPath), name)
	if _, err := os.Stat(src); err != nil {
		return fail(fmt.Errorf("sauvegarde introuvable : %s", name))
	}
	if err := checkSQLite(src); err != nil {
		return fail(fmt.Errorf("sauvegarde illisible (%s) : %v", name, err))
	}
	if _, err := os.Stat(dbPath); err == nil {
		before := "before-restore-" + time.Now().Format("20060102-150405") + ".db"
		dest := filepath.Join(BackupsDir(dbPath), before)
		if err := os.MkdirAll(BackupsDir(dbPath), 0o755); err != nil {
			return fail(err)
		}
		cur, err := Open(dbPath)
		if err != nil {
			return fail(fmt.Errorf("base actuelle illisible : %v", err))
		}
		_, err = cur.Exec(`VACUUM INTO ?`, dest)
		cur.Close()
		if err != nil {
			return fail(fmt.Errorf("copie de la base actuelle impossible : %v", err))
		}
		report.Before = before
	}
	tmp := dbPath + ".restoring"
	if err := copyFile(src, tmp); err != nil {
		os.Remove(tmp)
		return fail(err)
	}
	os.Remove(dbPath + "-wal")
	os.Remove(dbPath + "-shm")
	if err := os.Rename(tmp, dbPath); err != nil {
		os.Remove(tmp)
		return fail(err)
	}
	writeReport()
	return name, nil
}

func checkSQLite(path string) error {
	db, err := sql.Open("sqlite", fmt.Sprintf("file:%s?mode=ro", filepath.ToSlash(path)))
	if err != nil {
		return err
	}
	defer db.Close()
	var res string
	if err := db.QueryRow(`PRAGMA quick_check`).Scan(&res); err != nil {
		return err
	}
	if res != "ok" {
		return fmt.Errorf("%s", res)
	}
	return nil
}

func copyFile(src, dst string) error {
	in, err := os.Open(src)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.Create(dst)
	if err != nil {
		return err
	}
	if _, err := io.Copy(out, in); err != nil {
		out.Close()
		return err
	}
	if err := out.Sync(); err != nil {
		out.Close()
		return err
	}
	return out.Close()
}

// Seed creates the minimum rows a fresh install needs: a default warehouse and
// an admin user (username "admin", password "admin" — must be changed on first login).
func Seed(db *sql.DB) error {
	now := time.Now().UTC().Format(time.RFC3339)

	var warehouses int
	if err := db.QueryRow(`SELECT COUNT(*) FROM warehouses`).Scan(&warehouses); err != nil {
		return err
	}
	if warehouses == 0 {
		id, _ := uuid.NewV7()
		if _, err := db.Exec(`INSERT INTO warehouses (id, name, is_default, active, created_at, updated_at)
			VALUES (?, 'Magasin', 1, 1, ?, ?)`, id.String(), now, now); err != nil {
			return err
		}
	}

	var users int
	if err := db.QueryRow(`SELECT COUNT(*) FROM users`).Scan(&users); err != nil {
		return err
	}
	if users == 0 {
		hash, err := bcrypt.GenerateFromPassword([]byte("admin"), bcrypt.DefaultCost)
		if err != nil {
			return err
		}
		id, _ := uuid.NewV7()
		if _, err := db.Exec(`INSERT INTO users (id, username, password_hash, full_name, role, active, created_at, updated_at)
			VALUES (?, 'admin', ?, 'Administrateur', 'admin', 1, ?, ?)`, id.String(), string(hash), now, now); err != nil {
			return err
		}
	}
	return nil
}
