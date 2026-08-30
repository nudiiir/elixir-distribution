package main

import (
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"

	"github.com/kardianos/service"

	"elixir/server/internal/api"
	"elixir/server/internal/store"
)

type program struct {
	dbPath string
	addr   string
}

func (p *program) Start(_ service.Service) error {
	go p.run()
	return nil
}

func (p *program) Stop(_ service.Service) error { return nil }

func (p *program) run() {
	if dir := filepath.Dir(p.dbPath); dir != "." {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			log.Fatalf("create db dir: %v", err)
		}
	}
	db, err := store.Open(p.dbPath)
	if err != nil {
		log.Fatalf("open db: %v", err)
	}
	if err := store.Migrate(db); err != nil {
		log.Fatalf("migrate: %v", err)
	}
	if err := store.Seed(db); err != nil {
		log.Fatalf("seed: %v", err)
	}
	api.StartBackupScheduler(db, p.dbPath)

	log.Printf("elixir server listening on %s (db=%s)", p.addr, p.dbPath)
	if err := http.ListenAndServe(p.addr, api.New(db, p.dbPath)); err != nil {
		log.Fatal(err)
	}
}

func main() {
	// When running as a Windows service the working directory is System32 —
	// resolve default paths relative to the executable.
	exe, _ := os.Executable()
	exeDir := filepath.Dir(exe)

	var dbPath, addr, svcCmd string
	flag.StringVar(&dbPath, "db", filepath.Join(exeDir, "data", "elixir.db"),
		"path to the SQLite database file")
	flag.StringVar(&addr, "addr", "0.0.0.0:8543", "listen address")
	flag.StringVar(&svcCmd, "service", "",
		"service control: install | uninstall | start | stop")
	flag.Parse()

	prg := &program{dbPath: dbPath, addr: addr}
	cfg := &service.Config{
		Name:        "ElixirServer",
		DisplayName: "Elixir Gestion — Serveur",
		Description: "Serveur de gestion commerciale Elixir (base de données du magasin).",
		Arguments:   []string{"-db", dbPath, "-addr", addr},
	}
	svc, err := service.New(prg, cfg)
	if err != nil {
		log.Fatal(err)
	}

	if svcCmd != "" {
		if err := service.Control(svc, svcCmd); err != nil {
			log.Fatalf("service %s: %v", svcCmd, err)
		}
		fmt.Printf("service %s: OK\n", svcCmd)
		return
	}

	// svc.Run works both interactively and under the SCM.
	if err := svc.Run(); err != nil {
		log.Fatal(err)
	}
}
