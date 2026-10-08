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

	"github.com/go-chi/chi/v5"

	"elixir/server/internal/store"
)

// BackupDir returns the backups folder next to the database file.
func BackupDir(dbPath string) string {
	return store.BackupsDir(dbPath)
}

// RunBackup snapshots the live database with VACUUM INTO and prunes old
// copies (keeps the most recent 14). Safe while the server is running.
func RunBackup(db *sql.DB, dbPath string) (string, error) {
	return runBackupNamed(db, dbPath, "elixir-"+time.Now().Format("20060102-150405")+".db")
}

func runBackupNamed(db *sql.DB, dbPath, name string) (string, error) {
	dir := BackupDir(dbPath)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return "", err
	}
	dest := filepath.Join(dir, name)
	if _, err := os.Stat(dest); err == nil {
		// Two backups in the same second: keep both.
		dest = strings.TrimSuffix(dest, ".db") + "-2.db"
	}
	if _, err := db.Exec(`VACUUM INTO ?`, dest); err != nil {
		return "", err
	}
	// Retention: keep the 14 newest daily/manual copies.
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
	// daily | manual-like copies ("auto"), the copy taken before a restore
	// ("before_restore") or before a reset ("before_reset").
	Kind string `json:"kind"`
}

func backupKind(name string) string {
	switch {
	case strings.HasPrefix(name, "before-restore-"):
		return "before_restore"
	case strings.HasPrefix(name, "before-reset-"):
		return "before_reset"
	case strings.HasPrefix(name, "elixir-"):
		return "auto"
	}
	return ""
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
			kind := backupKind(e.Name())
			if kind == "" || !strings.HasSuffix(e.Name(), ".db") || e.IsDir() {
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
				Kind:      kind,
			})
		}
	}
	sort.Slice(items, func(i, j int) bool { return items[i].ModTime > items[j].ModTime })
	writeJSON(w, http.StatusOK, map[string]any{
		"dir":             dir,
		"items":           items,
		"pending_restore": store.ReadPendingRestore(s.dbPath),
		"last_restore":    store.ReadLastRestore(s.dbPath),
	})
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
	s.audit(r, "backup.run", "backup", filepath.Base(dest), "sauvegarde manuelle "+filepath.Base(dest))
	writeJSON(w, http.StatusOK, map[string]string{"path": dest, "name": filepath.Base(dest)})
}

// scheduleRestore records a restore to apply at the NEXT server start (the
// file cannot be swapped under a running server). Admin + typed confirmation.
func (s *Server) scheduleRestore(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	name := chi.URLParam(r, "name")
	var in struct {
		Confirm string `json:"confirm"`
	}
	if err := decode(r, &in); err != nil {
		writeErr(w, http.StatusBadRequest, err.Error())
		return
	}
	if strings.ToUpper(strings.TrimSpace(in.Confirm)) != "RESTAURER" {
		writeErr(w, http.StatusBadRequest, "Tapez RESTAURER pour confirmer.")
		return
	}
	if !store.ValidBackupName(name) || backupKind(name) == "" {
		writeErr(w, http.StatusBadRequest, "Nom de sauvegarde invalide.")
		return
	}
	if _, err := os.Stat(filepath.Join(BackupDir(s.dbPath), name)); err != nil {
		writeErr(w, http.StatusNotFound, "Sauvegarde introuvable.")
		return
	}
	if err := os.WriteFile(store.PendingRestorePath(s.dbPath), []byte(name), 0o644); err != nil {
		writeErr(w, http.StatusInternalServerError, fmt.Sprintf("impossible d’enregistrer la demande : %v", err))
		return
	}
	s.audit(r, "backup.restore_scheduled", "backup", name,
		"restauration de "+name+" prévue au prochain démarrage du serveur")
	writeJSON(w, http.StatusOK, map[string]string{"pending_restore": name})
}

// cancelRestore removes a pending restore.
func (s *Server) cancelRestore(w http.ResponseWriter, r *http.Request) {
	if !s.isAdmin(r) {
		forbid(w)
		return
	}
	name := store.ReadPendingRestore(s.dbPath)
	if name != "" {
		if err := os.Remove(store.PendingRestorePath(s.dbPath)); err != nil && !os.IsNotExist(err) {
			writeErr(w, http.StatusInternalServerError, err.Error())
			return
		}
		s.audit(r, "backup.restore_cancelled", "backup", name, "restauration de "+name+" annulée")
	}
	writeJSON(w, http.StatusOK, map[string]string{"pending_restore": ""})
}
