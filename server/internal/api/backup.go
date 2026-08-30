package api

import (
	"database/sql"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

// BackupDir returns the backups folder next to the database file.
func BackupDir(dbPath string) string {
	return filepath.Join(filepath.Dir(dbPath), "backups")
}

// RunBackup snapshots the live database with VACUUM INTO and prunes old
// copies (keeps the most recent 14). Safe while the server is running.
func RunBackup(db *sql.DB, dbPath string) (string, error) {
	dir := BackupDir(dbPath)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	name := "elixir-" + time.Now().Format("20060102-150405") + ".db"
	dest := filepath.Join(dir, name)
	if _, err := db.Exec(`VACUUM INTO ?`, dest); err != nil {
		return "", err
	}
	// Retention: keep the 14 newest.
	entries, err := os.ReadDir(dir)
	if err == nil {
		var files []string
		for _, e := range entries {
			if strings.HasPrefix(e.Name(), "elixir-") && strings.HasSuffix(e.Name(), ".db") {
				files = append(files, e.Name())
			}
		}
		sort.Sort(sort.Reverse(sort.StringSlice(files)))
		for i := 14; i < len(files); i++ {
			os.Remove(filepath.Join(dir, files[i]))
		}
	}
	return dest, nil
}

// StartBackupScheduler backs up once at startup if none exists for today,
// then re-checks hourly so a machine left on overnight gets a daily snapshot.
func StartBackupScheduler(db *sql.DB, dbPath string) {
	check := func() {
		today := time.Now().Format("20060102")
		entries, err := os.ReadDir(BackupDir(dbPath))
		if err == nil {
			for _, e := range entries {
				if strings.HasPrefix(e.Name(), "elixir-"+today) {
					return // already have one for today
				}
			}
		}
		if dest, err := RunBackup(db, dbPath); err != nil {
			log.Printf("backup FAILED: %v", err)
		} else {
			log.Printf("backup written: %s", dest)
		}
	}
	go func() {
		check()
		for range time.Tick(time.Hour) {
			check()
		}
	}()
}

type BackupInfo struct {
	Name      string `json:"name"`
	SizeBytes int64  `json:"size_bytes"`
	ModTime   string `json:"mod_time"`
}

func (s *Server) listBackups(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	dir := BackupDir(s.dbPath)
	entries, err := os.ReadDir(dir)
	items := []BackupInfo{}
	if err == nil {
		for _, e := range entries {
			if !strings.HasPrefix(e.Name(), "elixir-") || !strings.HasSuffix(e.Name(), ".db") {
				continue
			}
			info, err := e.Info()
			if err != nil {
				continue
			}
			items = append(items, BackupInfo{
				Name:      e.Name(),
				SizeBytes: info.Size(),
				ModTime:   info.ModTime().UTC().Format(time.RFC3339),
			})
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].Name > items[j].Name })
	writeJSON(w, http.StatusOK, map[string]any{"dir": dir, "items": items})
}

func (s *Server) runBackupNow(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	dest, err := RunBackup(s.db, s.dbPath)
	if err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Sprintf("sauvegarde échouée : %v", err))
		return
	}
	writeJSON(w, http.StatusOK, map[string]string{"path": dest})
}
