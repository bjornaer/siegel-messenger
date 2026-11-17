package main

import (
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"

	"connectrpc.com/connect"
	"github.com/jackc/pgx/v5"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
)

// maxBlob is MED-06's 1 GB of plaintext plus encryption overhead and MED-02 padding.
const maxBlob = 1 << 30 * 11 / 10

// largeBlob is where the shorter retention starts: over 100 MB of plaintext.
const largeBlob = 100 << 20 * 11 / 10

// partSize is how much of a blob goes in one request (the apps use the same): a phone holds
// one part at a time, and a dropped upload resumes at the part it stopped on.
const partSize = 8 << 20

// partKey is where part n of a blob uploaded in parts is kept.
func partKey(id []byte, n int) string { return fmt.Sprintf("%x.%d", id, n) }

// partLen is the length of part n of a blob of size bytes.
func partLen(size int64, n int) int64 { return min(partSize, size-int64(n)*partSize) }

// blobStore keeps attachment ciphertext (ARCH-06). Tests swap in a map.
type blobStore interface {
	put(ctx context.Context, key string, body io.Reader, size int64) error
	get(ctx context.Context, key string) (io.ReadCloser, error)
	getRange(ctx context.Context, key string, off, n int64) (io.ReadCloser, error)
	del(ctx context.Context, key string) error
}

type attachments struct{ *server }

func (s attachments) CreateUpload(ctx context.Context, req *connect.Request[siegelv1.AttachmentsServiceCreateUploadRequest]) (*connect.Response[siegelv1.AttachmentsServiceCreateUploadResponse], error) {
	size := req.Msg.Size
	if size <= 0 || size > maxBlob {
		return nil, cerr(connect.CodeInvalidArgument, "attachment_too_large")
	}
	acct := account(ctx)
	if okay, err := s.hit(ctx, "upload:"+hex.EncodeToString(acct[:]), 24*time.Hour, s.cfg.uploadsPerDay); err != nil {
		return nil, internal(err)
	} else if !okay {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited")
	}
	mb := int((size + 1<<20 - 1) >> 20)
	if okay, err := s.hitBy(ctx, "upload_mb:"+hex.EncodeToString(acct[:]), 24*time.Hour, mb, s.cfg.uploadMBDay); err != nil {
		return nil, internal(err)
	} else if !okay {
		return nil, cerr(connect.CodeResourceExhausted, "rate_limited")
	}
	id, token := make([]byte, 16), make([]byte, 16)
	rand.Read(id)
	rand.Read(token)
	h := sha256.Sum256(token)
	exp, renewable := time.Now().Add(s.cfg.blobLife), req.Msg.Renewable
	if size > largeBlob {
		exp, renewable = time.Now().Add(s.cfg.largeLife), false
	}
	if _, err := s.db.Exec(ctx, `INSERT INTO attachments (blob_id, size, upload_hash, expires_at, renewable) VALUES ($1, $2, $3, $4, $5)`,
		id, size, h[:], exp, renewable); err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.AttachmentsServiceCreateUploadResponse{
		BlobId:     id,
		UploadPath: "/v1/blobs/" + hex.EncodeToString(id) + "?t=" + base64.RawURLEncoding.EncodeToString(token),
		ExpiresAt:  exp.Unix(),
	}), nil
}

func (s attachments) Keep(ctx context.Context, req *connect.Request[siegelv1.AttachmentsServiceKeepRequest]) (*connect.Response[siegelv1.AttachmentsServiceKeepResponse], error) {
	if _, err := s.db.Exec(ctx, `UPDATE attachments SET expires_at = $2
		WHERE blob_id = $1 AND renewable AND upload_hash IS NULL AND expires_at > now() AND expires_at < $2`,
		req.Msg.BlobId, time.Now().Add(s.cfg.blobLife)); err != nil {
		return nil, internal(err)
	}
	return connect.NewResponse(&siegelv1.AttachmentsServiceKeepResponse{}), nil
}

// putBlob takes the ciphertext for a reserved blob, once (MED-03). The token in the URL is the
// only credential: anyone holding it may upload, which is the point of a pre-signed URL.
func (s *server) putBlob(w http.ResponseWriter, r *http.Request) {
	id, err := hex.DecodeString(r.PathValue("id"))
	token, err2 := base64.RawURLEncoding.DecodeString(r.URL.Query().Get("t"))
	if err != nil || err2 != nil || len(id) != 16 {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	h := sha256.Sum256(token)
	if r.URL.Query().Has("part") {
		s.putPart(w, r, id, h[:])
		return
	}
	var size int64
	err = s.db.QueryRow(r.Context(), `UPDATE attachments SET upload_hash = NULL
		WHERE blob_id = $1 AND upload_hash = $2 AND expires_at > now() RETURNING size`, id, h[:]).Scan(&size)
	if errors.Is(err, pgx.ErrNoRows) {
		http.Error(w, "not found", http.StatusNotFound) // unknown, used or expired
		return
	} else if err != nil {
		slog.Error("blob put", "err", err)
		http.Error(w, "internal", http.StatusInternalServerError)
		return
	}
	if r.ContentLength != size {
		s.releaseUpload(id, h[:])
		http.Error(w, "size mismatch", http.StatusBadRequest)
		return
	}
	noDeadline(w, r)
	if err := s.blobs.put(r.Context(), hex.EncodeToString(id), r.Body, size); err != nil {
		slog.Error("blob put", "err", err)
		s.releaseUpload(id, h[:])
		http.Error(w, "upload failed", http.StatusBadGateway)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// putPart takes part n of a blob, in order. Any other part is refused with the one expected
// next in X-Next-Part, so an app that lost track resumes there; the last part completes it.
func (s *server) putPart(w http.ResponseWriter, r *http.Request, id, hash []byte) {
	n, err := strconv.Atoi(r.URL.Query().Get("part"))
	var size int64
	var done int
	if err == nil {
		err = s.db.QueryRow(r.Context(), `SELECT size, parts FROM attachments
			WHERE blob_id = $1 AND upload_hash = $2 AND expires_at > now()`, id, hash).Scan(&size, &done)
	}
	if errors.Is(err, pgx.ErrNoRows) {
		http.Error(w, "not found", http.StatusNotFound) // unknown, finished or expired
		return
	} else if err != nil {
		http.Error(w, "bad request", http.StatusBadRequest)
		return
	}
	if n != done {
		w.Header().Set("X-Next-Part", strconv.Itoa(done))
		http.Error(w, "out of order", http.StatusConflict)
		return
	}
	if r.ContentLength != partLen(size, n) {
		http.Error(w, "size mismatch", http.StatusBadRequest)
		return
	}
	noDeadline(w, r)
	if err := s.blobs.put(r.Context(), partKey(id, n), r.Body, r.ContentLength); err != nil {
		slog.Error("blob part put", "err", err)
		http.Error(w, "upload failed", http.StatusBadGateway)
		return
	}
	last := int64(n+1)*partSize >= size
	tag, err := s.db.Exec(r.Context(), `UPDATE attachments SET parts = parts + 1,
		upload_hash = CASE WHEN $4 THEN NULL ELSE upload_hash END
		WHERE blob_id = $1 AND upload_hash = $2 AND parts = $3`, id, hash, n, last)
	if err != nil || tag.RowsAffected() == 0 {
		w.Header().Set("X-Next-Part", strconv.Itoa(n+1)) // a twin request got there first
		http.Error(w, "out of order", http.StatusConflict)
		return
	}
	w.WriteHeader(http.StatusNoContent)
}

// releaseUpload lets the client retry a failed upload with the same URL.
func (s *server) releaseUpload(id, hash []byte) {
	if _, err := s.db.Exec(context.Background(), `UPDATE attachments SET upload_hash = $2 WHERE blob_id = $1`, id, hash); err != nil {
		slog.Error("blob release", "err", err)
	}
}

// getBlob serves ciphertext to any signed-in device that knows the blob ID; only the
// attachment message, inside MLS, carries the ID and the key.
func (s *server) getBlob(w http.ResponseWriter, r *http.Request) {
	_, found, err := s.authenticate(r.Context(), r.Header.Get("Authorization"))
	if err != nil || !found {
		http.Error(w, "unauthenticated", http.StatusUnauthorized)
		return
	}
	id, err := hex.DecodeString(r.PathValue("id"))
	var size int64
	var parts int
	if err == nil {
		err = s.db.QueryRow(r.Context(), `SELECT size, parts FROM attachments
			WHERE blob_id = $1 AND upload_hash IS NULL AND expires_at > now()`, id).Scan(&size, &parts)
	}
	if err != nil {
		http.Error(w, "attachment_expired", http.StatusNotFound) // MED-13
		return
	}
	// ?part=n is one part, so a dropped download resumes there. A blob uploaded whole gives the
	// same byte range of itself.
	open := func(n int) (io.ReadCloser, error) {
		if parts == 0 {
			return s.blobs.getRange(r.Context(), hex.EncodeToString(id), int64(n)*partSize, partLen(size, n))
		}
		return s.blobs.get(r.Context(), partKey(id, n))
	}
	var bodies []func() (io.ReadCloser, error)
	length := size
	switch q := r.URL.Query(); {
	case q.Has("part"):
		n, err := strconv.Atoi(q.Get("part"))
		if err != nil || n < 0 || int64(n)*partSize >= size {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}
		bodies, length = []func() (io.ReadCloser, error){func() (io.ReadCloser, error) { return open(n) }}, partLen(size, n)
	case parts == 0:
		bodies = []func() (io.ReadCloser, error){func() (io.ReadCloser, error) { return s.blobs.get(r.Context(), hex.EncodeToString(id)) }}
	default: // an older app: the parts, joined
		for n := range parts {
			bodies = append(bodies, func() (io.ReadCloser, error) { return s.blobs.get(r.Context(), partKey(id, n)) })
		}
	}
	noDeadline(w, r)
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", fmt.Sprint(length))
	for i, b := range bodies {
		body, err := b()
		if err != nil {
			slog.Error("blob get", "err", err)
			if i == 0 {
				http.Error(w, "internal", http.StatusBadGateway)
			}
			return // mid-way: the short body tells the app it failed
		}
		_, err = io.Copy(w, body)
		body.Close()
		if err != nil {
			return
		}
	}
}

// noDeadline lifts the 30 s unary timeouts: 100 MB on a slow phone link takes minutes.
// ponytail: no deadline at all; add an idle timeout if stalled transfers pile up.
func noDeadline(w http.ResponseWriter, _ *http.Request) {
	rc := http.NewResponseController(w)
	_ = rc.SetReadDeadline(time.Time{})
	_ = rc.SetWriteDeadline(time.Time{})
}

// expireBlobs deletes blobs past their retention (MED-13), store first so none are orphaned.
func (s *server) expireBlobs(ctx context.Context) {
	type expired struct {
		ID    []byte
		Parts int
	}
	rows, err := s.db.Query(ctx, `SELECT blob_id, parts FROM attachments WHERE expires_at < now() LIMIT 10000`)
	if err != nil {
		slog.Error("blob expiry", "err", err)
		return
	}
	blobs, err := pgx.CollectRows(rows, pgx.RowToStructByPos[expired])
	if err != nil {
		slog.Error("blob expiry", "err", err)
		return
	}
	for _, b := range blobs {
		id := b.ID
		keys := []string{hex.EncodeToString(id)}
		if b.Parts > 0 {
			keys = nil
			for n := range b.Parts {
				keys = append(keys, partKey(id, n))
			}
		}
		var err error
		for _, k := range keys {
			if err = s.blobs.del(ctx, k); err != nil {
				break
			}
		}
		if err != nil {
			slog.Error("blob expiry", "err", err)
			continue
		}
		if _, err := s.db.Exec(ctx, `DELETE FROM attachments WHERE blob_id = $1`, id); err != nil {
			slog.Error("blob expiry", "err", err)
		}
	}
}

// s3 is a path-style S3 client for the three calls we need, signed with SigV4 and an
// unsigned payload (the store is on a private network; TLS-less is fine there).
type s3 struct {
	endpoint, bucket, region, access, secret string
}

func (c s3) put(ctx context.Context, key string, body io.Reader, size int64) error {
	req, err := c.request(ctx, http.MethodPut, key, body)
	if err != nil {
		return err
	}
	req.ContentLength = size
	return c.do(req, nil)
}

func (c s3) get(ctx context.Context, key string) (io.ReadCloser, error) {
	req, err := c.request(ctx, http.MethodGet, key, nil)
	if err != nil {
		return nil, err
	}
	var body io.ReadCloser
	return body, c.do(req, &body)
}

func (c s3) getRange(ctx context.Context, key string, off, n int64) (io.ReadCloser, error) {
	req, err := c.request(ctx, http.MethodGet, key, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Range", fmt.Sprintf("bytes=%d-%d", off, off+n-1)) // unsigned: SigV4 allows it
	var body io.ReadCloser
	return body, c.do(req, &body)
}

func (c s3) del(ctx context.Context, key string) error {
	req, err := c.request(ctx, http.MethodDelete, key, nil)
	if err != nil {
		return err
	}
	return c.do(req, nil)
}

// makeBucket creates the bucket; "already exists" counts as success.
func (c s3) makeBucket(ctx context.Context) error {
	req, err := c.request(ctx, http.MethodPut, "", nil)
	if err != nil {
		return err
	}
	err = c.do(req, nil)
	if err != nil && strings.Contains(err.Error(), "BucketAlready") {
		return nil
	}
	return err
}

func (c s3) do(req *http.Request, body *io.ReadCloser) error {
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	if res.StatusCode/100 != 2 {
		defer res.Body.Close()
		msg, _ := io.ReadAll(io.LimitReader(res.Body, 512))
		return fmt.Errorf("s3 %s: %d %s", req.Method, res.StatusCode, msg)
	}
	if body != nil {
		*body = res.Body
		return nil
	}
	return res.Body.Close()
}

func (c s3) request(ctx context.Context, method, key string, body io.Reader) (*http.Request, error) {
	path := "/" + c.bucket
	if key != "" {
		path += "/" + key
	}
	req, err := http.NewRequestWithContext(ctx, method, c.endpoint+path, body)
	if err != nil {
		return nil, err
	}
	c.sign(req, time.Now().UTC())
	return req, nil
}

// sign adds AWS Signature Version 4 headers.
func (c s3) sign(req *http.Request, now time.Time) {
	const payload = "UNSIGNED-PAYLOAD"
	stamp, day := now.Format("20060102T150405Z"), now.Format("20060102")
	req.Header.Set("X-Amz-Date", stamp)
	req.Header.Set("X-Amz-Content-Sha256", payload)
	canonical := strings.Join([]string{req.Method, req.URL.EscapedPath(), req.URL.RawQuery,
		"host:" + req.URL.Host, "x-amz-content-sha256:" + payload, "x-amz-date:" + stamp, "",
		"host;x-amz-content-sha256;x-amz-date", payload}, "\n")
	scope := day + "/" + c.region + "/s3/aws4_request"
	sum := sha256.Sum256([]byte(canonical))
	toSign := "AWS4-HMAC-SHA256\n" + stamp + "\n" + scope + "\n" + hex.EncodeToString(sum[:])
	k := []byte("AWS4" + c.secret)
	for _, part := range []string{day, c.region, "s3", "aws4_request", toSign} {
		m := hmac.New(sha256.New, k)
		m.Write([]byte(part))
		k = m.Sum(nil)
	}
	req.Header.Set("Authorization", "AWS4-HMAC-SHA256 Credential="+c.access+"/"+scope+
		", SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature="+hex.EncodeToString(k))
}
