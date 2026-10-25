// SPDX-License-Identifier: MIT
//
// A HashiCorp Raft node replicating a "chain of blocks": every command is a block of bytes, and
// the state machine is the number of blocks applied and the running hash over them, so replicas
// that applied the same blocks in the same order hold the same hash.
//
// Raft runs on port 7000 (TCP transport), an HTTP API on 8000:
//
//	POST /submit   the body is one block: applied through the leader ("ok <index>"), or 409 with
//	               the leader's address when this node is not the leader
//	GET  /state    {"applied": N, "hash": "<hex>", "leader": bool}
//	GET  /hash?n=N the hash after the first N blocks (404 if not applied yet)
//
// Usage: raft-node -id raft-1 -peers raft-1,raft-2,raft-3 -data /var/lib/raft
package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/hashicorp/raft"
	raftboltdb "github.com/hashicorp/raft-boltdb/v2"
)

const (
	raftPort = "7000"
	httpPort = "8000"
)

// chain is the state machine: the blocks' running hash, with its history (one hash per block
// applied), so that replicas can be compared at the same length.
type chain struct {
	mu     sync.Mutex
	hashes []string
	last   [sha256.Size]byte
}

func (c *chain) Apply(entry *raft.Log) interface{} {
	c.mu.Lock()
	defer c.mu.Unlock()
	next := sha256.New()
	next.Write(c.last[:])
	next.Write(entry.Data)
	copy(c.last[:], next.Sum(nil))
	c.hashes = append(c.hashes, hex.EncodeToString(c.last[:]))
	return len(c.hashes)
}

type snapshot struct{ hashes []string }

func (c *chain) Snapshot() (raft.FSMSnapshot, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	return &snapshot{hashes: append([]string(nil), c.hashes...)}, nil
}

func (s *snapshot) Persist(sink raft.SnapshotSink) error {
	if err := json.NewEncoder(sink).Encode(s.hashes); err != nil {
		sink.Cancel()
		return err
	}
	return sink.Close()
}

func (s *snapshot) Release() {}

func (c *chain) Restore(reader io.ReadCloser) error {
	defer reader.Close()
	var hashes []string
	if err := json.NewDecoder(reader).Decode(&hashes); err != nil {
		return err
	}
	c.mu.Lock()
	defer c.mu.Unlock()
	c.hashes = hashes
	c.last = [sha256.Size]byte{}
	if len(hashes) > 0 {
		last, err := hex.DecodeString(hashes[len(hashes)-1])
		if err != nil {
			return err
		}
		copy(c.last[:], last)
	}
	return nil
}

func main() {
	id := flag.String("id", "", "this node's name")
	peers := flag.String("peers", "", "every node's name, comma-separated")
	data := flag.String("data", "/var/lib/raft", "where Raft keeps its log and snapshots")
	flag.Parse()
	if *id == "" || *peers == "" {
		log.Fatal("usage: raft-node -id <name> -peers <a,b,c> [-data <dir>]")
	}
	if err := os.MkdirAll(*data, 0o755); err != nil {
		log.Fatal(err)
	}
	machine := &chain{}
	node, err := start(*id, strings.Split(*peers, ","), *data, machine)
	if err != nil {
		log.Fatal(err)
	}
	serve(node, machine)
}

func start(id string, peers []string, data string, machine *chain) (*raft.Raft, error) {
	config := raft.DefaultConfig()
	config.LocalID = raft.ServerID(id)
	advertise, err := net.ResolveTCPAddr("tcp", id+":"+raftPort)
	if err != nil {
		return nil, err
	}
	transport, err := raft.NewTCPTransport(":"+raftPort, advertise, 3, 2*time.Second, os.Stderr)
	if err != nil {
		return nil, err
	}
	store, err := raftboltdb.NewBoltStore(filepath.Join(data, "raft.db"))
	if err != nil {
		return nil, err
	}
	snapshots, err := raft.NewFileSnapshotStore(data, 2, os.Stderr)
	if err != nil {
		return nil, err
	}
	node, err := raft.NewRaft(config, machine, store, store, snapshots, transport)
	if err != nil {
		return nil, err
	}
	existing, err := raft.HasExistingState(store, store, snapshots)
	if err != nil {
		return nil, err
	}
	if !existing { // The same configuration on every node: whichever wins the election leads.
		servers := make([]raft.Server, 0, len(peers))
		for _, peer := range peers {
			address := raft.ServerAddress(peer + ":" + raftPort)
			servers = append(servers, raft.Server{ID: raft.ServerID(peer), Address: address})
		}
		node.BootstrapCluster(raft.Configuration{Servers: servers})
	}
	return node, nil
}

func serve(node *raft.Raft, machine *chain) {
	http.HandleFunc("/submit", func(w http.ResponseWriter, r *http.Request) {
		block, err := io.ReadAll(r.Body)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if node.State() != raft.Leader {
			leader, _ := node.LeaderWithID()
			http.Error(w, "leader "+string(leader), http.StatusConflict)
			return
		}
		future := node.Apply(block, 2*time.Second)
		if err := future.Error(); err != nil {
			http.Error(w, err.Error(), http.StatusServiceUnavailable)
			return
		}
		fmt.Fprintf(w, "ok %d\n", future.Response())
	})
	http.HandleFunc("/state", func(w http.ResponseWriter, r *http.Request) {
		machine.mu.Lock()
		state := map[string]interface{}{
			"applied": len(machine.hashes),
			"hash":    hex.EncodeToString(machine.last[:]),
			"leader":  node.State() == raft.Leader,
		}
		machine.mu.Unlock()
		json.NewEncoder(w).Encode(state)
	})
	http.HandleFunc("/hash", func(w http.ResponseWriter, r *http.Request) {
		n, err := strconv.Atoi(r.URL.Query().Get("n"))
		machine.mu.Lock()
		defer machine.mu.Unlock()
		if err != nil || n < 1 || n > len(machine.hashes) {
			http.Error(w, "not applied", http.StatusNotFound)
			return
		}
		fmt.Fprintln(w, machine.hashes[n-1])
	})
	log.Fatal(http.ListenAndServe(":"+httpPort, nil))
}
