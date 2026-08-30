package store

import (
	"database/sql"
	"embed"
	"fmt"
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
