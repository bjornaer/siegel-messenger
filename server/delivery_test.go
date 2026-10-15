package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"net/http"
	"strings"
	"testing"
	"time"

	"connectrpc.com/connect"
	"github.com/coder/websocket"
	"google.golang.org/protobuf/proto"

	siegelv1 "github.com/bjornaer/siegel-messenger/server/gen/siegel/v1"
	"github.com/bjornaer/siegel-messenger/server/gen/siegel/v1/siegelv1connect"
)

type device struct {
	*siegelv1.VerifyResponse
	keys   siegelv1connect.KeysServiceClient
	msgs   siegelv1connect.MessagesServiceClient
	groups siegelv1connect.GroupsServiceClient
}

func (e *env_) device(phone string) device {
	res, err := e.register(phone, "")
	if err != nil {
		e.t.Fatal(err)
	}
	auth := connect.WithInterceptors(connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
		return func(ctx context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
			r.Header().Set("Authorization", "Bearer "+res.DeviceToken)
			return next(ctx, r)
		}
	}))
	return device{res, siegelv1connect.NewKeysServiceClient(http.DefaultClient, e.url, auth),
		siegelv1connect.NewMessagesServiceClient(http.DefaultClient, e.url, auth),
		siegelv1connect.NewGroupsServiceClient(http.DefaultClient, e.url, auth)}
}

func (d device) addr() *siegelv1.DeviceAddress {
	return &siegelv1.DeviceAddress{AccountId: d.AccountId, DeviceId: d.DeviceId}
}

func TestKeyPackages(t *testing.T) { // CRY-09, GRP-09
	e := setup(t)
	a, b := e.device("+34600000051"), e.device("+34600000052")
	up, err := a.keys.Upload(e.ctx, connect.NewRequest(&siegelv1.KeysServiceUploadRequest{
		KeyPackages: [][]byte{[]byte("kp1"), []byte("kp2")}, LastResort: []byte("lr")}))
	if err != nil || up.Msg.Remaining != 2 {
		t.Fatal("upload", err)
	}
	var got []string
	for range 4 {
		res, err := b.keys.Claim(e.ctx, connect.NewRequest(&siegelv1.KeysServiceClaimRequest{AccountId: a.AccountId}))
		if err != nil || len(res.Msg.KeyPackages) != 1 || !bytes.Equal(res.Msg.KeyPackages[0].DeviceId, a.DeviceId) {
			t.Fatal("claim", err)
		}
		got = append(got, string(res.Msg.KeyPackages[0].KeyPackage))
	}
	want(t, strings.Join(got, ","), "kp1,kp2,lr,lr") // one-time packages are consumed, last resort stays

	up, _ = a.keys.Upload(e.ctx, connect.NewRequest(&siegelv1.KeysServiceUploadRequest{}))
	if up.Msg.Remaining != 0 {
		t.Fatal("remaining after claims", up.Msg.Remaining)
	}
	_, err = a.keys.Claim(e.ctx, connect.NewRequest(&siegelv1.KeysServiceClaimRequest{AccountId: b.AccountId}))
	want(t, errMsg(err), "no_key_packages")
	e.s.cfg.claimPerDay = 0
	_, err = b.keys.Claim(e.ctx, connect.NewRequest(&siegelv1.KeysServiceClaimRequest{AccountId: a.AccountId}))
	want(t, errMsg(err), "rate_limited")
}

func TestCommitOrdering(t *testing.T) { // CRY-14
	e := setup(t)
	a, b := e.device("+34600000061"), e.device("+34600000062")
	commit := func(d device, epoch uint64, welcome bool) error {
		req := &siegelv1.GroupsServiceCommitRequest{GroupId: []byte("group-1"), Epoch: epoch, Commit: []byte("c"),
			Recipients: []*siegelv1.DeviceAddress{a.addr(), b.addr()}}
		if welcome {
			req.Welcome, req.WelcomeRecipients = []byte("w"), []*siegelv1.DeviceAddress{b.addr()}
		}
		_, err := d.groups.Commit(e.ctx, connect.NewRequest(req))
		return err
	}
	if err := commit(a, 0, true); err != nil {
		t.Fatal(err)
	}
	want(t, errMsg(commit(b, 0, false)), "epoch_conflict") // group already exists
	if err := commit(b, 1, false); err != nil {            // b moves 1 -> 2
		t.Fatal(err)
	}
	want(t, errMsg(commit(a, 1, false)), "epoch_conflict") // a lost the race for epoch 1
	if err := commit(a, 2, false); err != nil {
		t.Fatal("rebased commit", err)
	}
	var queued int
	e.s.db.QueryRow(e.ctx, `SELECT count(*) FROM queue WHERE payload = 'w'`).Scan(&queued)
	if queued != 1 {
		t.Fatal("welcome queued for new member only", queued)
	}
}

func dial(e *env_, token string) (*websocket.Conn, *http.Response, error) {
	h := http.Header{}
	if token != "" {
		h.Set("Authorization", "Bearer "+token)
	}
	return websocket.Dial(e.ctx, "ws"+strings.TrimPrefix(e.url, "http")+"/v1/stream", &websocket.DialOptions{HTTPHeader: h})
}

func next(t *testing.T, c *websocket.Conn) *siegelv1.StreamFrame {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_, b, err := c.Read(ctx)
	if err != nil {
		t.Fatal("read frame", err)
	}
	var f siegelv1.StreamFrame
	if err := proto.Unmarshal(b, &f); err != nil {
		t.Fatal(err)
	}
	return &f
}

func TestStream(t *testing.T) { // SRV-03, MSG-06, ID-12, ID-13
	e := setup(t)
	e.s.cfg.otpPerNumber = 100
	a, b := e.device("+34600000071"), e.device("+34600000072")
	send := func(payload string) *siegelv1.MessagesServiceSendIdentifiedResponse {
		res, err := a.msgs.SendIdentified(e.ctx, connect.NewRequest(&siegelv1.MessagesServiceSendIdentifiedRequest{
			Recipients: []*siegelv1.DeviceAddress{b.addr()}, Payload: []byte(payload)}))
		if err != nil {
			t.Fatal(err)
		}
		return res.Msg
	}
	send("queued while offline")

	if _, res, _ := dial(e, ""); res == nil || res.StatusCode != http.StatusUnauthorized {
		t.Fatal("stream without token must be 401")
	}
	ws, _, err := dial(e, b.DeviceToken)
	if err != nil {
		t.Fatal(err)
	}
	defer ws.CloseNow()
	f := next(t, ws)
	want(t, string(f.GetMessage().GetPayload()), "queued while offline")

	send("live") // arrives through LISTEN/NOTIFY
	live := next(t, ws).GetMessage()
	want(t, string(live.GetPayload()), "live")

	ack, _ := proto.Marshal(&siegelv1.StreamAck{Ids: []int64{f.GetMessage().Id, live.Id}})
	ws.Write(e.ctx, websocket.MessageBinary, ack)
	for i := 0; ; i++ {
		var n int
		e.s.db.QueryRow(e.ctx, `SELECT count(*) FROM queue`).Scan(&n)
		if n == 0 {
			break
		}
		if i > 50 {
			t.Fatal("ack did not delete queued messages")
		}
		time.Sleep(20 * time.Millisecond)
	}

	// Re-registering b's number revokes the connected device: it is told to wipe (ID-12) and
	// senders learn the old device is gone (ID-13).
	if _, err := e.register("+34600000072", ""); err != nil {
		t.Fatal(err)
	}
	if next(t, ws).GetDeregistered() == nil {
		t.Fatal("connected revoked device must get deregistered")
	}
	if r := send("to revoked"); len(r.Revoked) != 1 {
		t.Fatal("revoked device not reported")
	}
	old, _, err := dial(e, b.DeviceToken)
	if err != nil {
		t.Fatal(err)
	}
	defer old.CloseNow()
	if next(t, old).GetDeregistered() == nil {
		t.Fatal("reconnecting revoked device must get deregistered")
	}
}

func TestProfilesAndSealedSender(t *testing.T) { // MSG-10, CMP-04
	e := setup(t)
	a, b := e.device("+34600000081"), e.device("+34600000082")
	auth := func(token string) connect.ClientOption {
		return connect.WithInterceptors(connect.UnaryInterceptorFunc(func(next connect.UnaryFunc) connect.UnaryFunc {
			return func(ctx context.Context, r connect.AnyRequest) (connect.AnyResponse, error) {
				r.Header().Set("Authorization", "Bearer "+token)
				return next(ctx, r)
			}
		}))
	}
	bp := siegelv1connect.NewProfileServiceClient(http.DefaultClient, e.url, auth(b.DeviceToken))
	ap := siegelv1connect.NewProfileServiceClient(http.DefaultClient, e.url, auth(a.DeviceToken))
	token := []byte("bob's delivery token, derived from his profile key")
	verifier := sha256.Sum256(token)
	if _, err := bp.Set(e.ctx, connect.NewRequest(&siegelv1.ProfileServiceSetRequest{
		EncryptedProfile: []byte("ciphertext"), DeliveryTokenVerifier: verifier[:]})); err != nil {
		t.Fatal(err)
	}
	got, err := ap.Get(e.ctx, connect.NewRequest(&siegelv1.ProfileServiceGetRequest{AccountId: b.AccountId}))
	if err != nil || string(got.Msg.EncryptedProfile) != "ciphertext" {
		t.Fatal("profile get", err)
	}
	_, err = bp.Get(e.ctx, connect.NewRequest(&siegelv1.ProfileServiceGetRequest{AccountId: a.AccountId}))
	want(t, errMsg(err), "profile_not_found")

	// Anonymous client: no Authorization header at all.
	anon := siegelv1connect.NewMessagesServiceClient(http.DefaultClient, e.url)
	send := func(to device, tok []byte) *siegelv1.MessagesServiceSendSealedResponse {
		res, err := anon.SendSealed(e.ctx, connect.NewRequest(&siegelv1.MessagesServiceSendSealedRequest{
			Recipients: []*siegelv1.SealedRecipient{{Address: to.addr(), DeliveryToken: tok}}, Payload: []byte("sealed")}))
		if err != nil {
			t.Fatal(err)
		}
		return res.Msg
	}
	if r := send(b, token); len(r.Rejected) != 0 {
		t.Fatal("valid token rejected")
	}
	if r := send(b, []byte("guess")); len(r.Rejected) != 1 {
		t.Fatal("wrong token accepted")
	}
	if r := send(a, token); len(r.Rejected) != 1 {
		t.Fatal("recipient without a profile must reject")
	}
	var queued int
	e.s.db.QueryRow(e.ctx, `SELECT count(*) FROM queue WHERE payload = 'sealed'`).Scan(&queued)
	if queued != 1 {
		t.Fatal("exactly the valid sealed message is queued", queued)
	}

	e.s.cfg.newChatPerDay = 1
	commit := func(id string) error {
		_, err := a.groups.Commit(e.ctx, connect.NewRequest(&siegelv1.GroupsServiceCommitRequest{
			GroupId: []byte(id), Epoch: 0, Commit: []byte("c")}))
		return err
	}
	if err := commit("chat-1"); err != nil {
		t.Fatal(err)
	}
	want(t, errMsg(commit("chat-2")), "rate_limited") // CMP-04
}
