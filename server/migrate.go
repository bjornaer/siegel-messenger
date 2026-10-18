package main

import (
	"context"
	"embed"
	"fmt"
	"io/fs"
	"log/slog"
	"strconv"
	"strings"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgxpool"
)

// Schema changes are numbered files, NNNN_what.sql, each applied once in its own transaction
// and never edited after it ships: change the schema with a new file.
//
//go:embed migrations/*.sql
var migrations embed.FS

// migrate applies the migrations this database hasn't had. An advisory lock keeps two
// servers starting at once from racing.
func migrate(ctx context.Context, db *pgxpool.Pool) error {
	names, err := fs.Glob(migrations, "migrations/*.sql")
	if err != nil {
		return err
	}
	conn, err := db.Acquire(ctx)
	if err != nil {
		return err
	}
	defer conn.Release()
	if _, err := conn.Exec(ctx, `SELECT pg_advisory_lock(7351)`); err != nil {
		return err
	}
	defer conn.Exec(context.Background(), `SELECT pg_advisory_unlock(7351)`)
	if _, err := conn.Exec(ctx, `CREATE TABLE IF NOT EXISTS schema_migrations (
		version int PRIMARY KEY, name text NOT NULL, applied_at timestamptz NOT NULL DEFAULT now())`); err != nil {
		return err
	}
	for _, name := range names { // fs.Glob sorts
		base := strings.TrimPrefix(name, "migrations/")
		v, err := strconv.Atoi(strings.SplitN(base, "_", 2)[0])
		if err != nil {
			return fmt.Errorf("migration %s: name must start with its number", base)
		}
		var done bool
		if err := conn.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM schema_migrations WHERE version = $1)`, v).Scan(&done); err != nil {
			return err
		} else if done {
			continue
		}
		sql, _ := migrations.ReadFile(name)
		if err := pgx.BeginFunc(ctx, conn, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, string(sql)); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO schema_migrations (version, name) VALUES ($1, $2)`, v, base)
			return err
		}); err != nil {
			return fmt.Errorf("migration %s: %w", base, err)
		}
		slog.Info("migrated", "migration", base)
	}
	return nil
}
