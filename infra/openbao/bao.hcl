# Production OpenBao for Siegel (docs/deploy.md). Persistent raft storage, manual Shamir unseal.
# ponytail: plaintext listener, reachable only on the Hetzner private network; add TLS if the network is ever shared.
storage "raft" {
  path    = "/openbao/file"
  node_id = "bao1"
}
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}
api_addr      = "http://127.0.0.1:8200"
cluster_addr  = "http://127.0.0.1:8201"
disable_mlock = true
