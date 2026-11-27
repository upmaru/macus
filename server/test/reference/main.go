// Fixture-only driver of the official Incus client. Never installed in Macus.
package main

import (
	"context"
	"crypto/x509"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"os"
	"time"

	incus "github.com/lxc/incus/v7/client"
	"github.com/lxc/incus/v7/shared/api"
	localtls "github.com/lxc/incus/v7/shared/tls"
)

type Input struct {
	Socket      string         `json:"socket"`
	URL         string         `json:"url"`
	ServerCert  string         `json:"server_cert"`
	ClientCert  string         `json:"client_cert"`
	ClientKey   string         `json:"client_key"`
	TLSCA       string         `json:"tls_ca"`
	Protocol    string         `json:"protocol"`
	Payload     []byte         `json:"payload"`
	ReadInitial int            `json:"read_initial"`
	HalfClose   bool           `json:"half_close"`
	CloseWrite  bool           `json:"close_write"`
	Repeat      int            `json:"repeat"`
	IntervalMS  int            `json:"interval_ms"`
	Method      string         `json:"method"`
	Path        string         `json:"path"`
	Body        map[string]any `json:"body"`
	ETag        string         `json:"etag"`
	// Typed official-client calls for identity and certificate trust fixtures.
	Action      string `json:"action"`
	Certificate string `json:"certificate"`
	Name        string `json:"name"`
	Fingerprint string `json:"fingerprint"`
	Token       string `json:"token"`
}

func main() {
	var input Input
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: reference-driver INPUT_JSON")
		os.Exit(1)
	}
	file, err := os.Open(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer file.Close()
	if err := json.NewDecoder(file).Decode(&input); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	args := &incus.ConnectionArgs{SkipGetServer: input.Protocol == "" && input.Action == "", TLSServerCert: input.ServerCert,
		TLSClientCert: input.ClientCert, TLSClientKey: input.ClientKey, TLSCA: input.TLSCA}
	var client incus.InstanceServer
	err = nil
	if input.Socket != "" {
		client, err = incus.ConnectIncusUnixWithContext(ctx, input.Socket, args)
	} else {
		client, err = incus.ConnectIncusWithContext(ctx, input.URL, args)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer client.Disconnect()
	if input.Action != "" {
		typedCall(client, input)
		return
	}
	if input.Protocol != "" {
		rawConnection(client, input)
		return
	}
	var body any
	if input.Body != nil {
		body = input.Body
	}
	response, etag, err := client.RawQuery(input.Method, input.Path, body, input.ETag)
	result := map[string]any{"response": response, "etag": etag}
	if err != nil {
		result["error"] = err.Error()
		if status, ok := api.StatusErrorMatch(err); ok {
			result["error_status"] = status
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func rawConnection(client incus.InstanceServer, input Input) {
	var conn net.Conn
	var err error
	switch input.Protocol {
	case "sftp":
		conn, err = client.GetInstanceFileSFTPConn("fixture")
	case "nbd":
		conn, err = client.GetInstanceNBDConn("fixture", incus.InstanceNBDArgs{})
	default:
		err = fmt.Errorf("unknown fixture protocol")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer conn.Close()
	interval := time.Duration(input.IntervalMS) * time.Millisecond
	_ = conn.SetDeadline(time.Now().Add(3*time.Second + time.Duration(input.Repeat)*interval))
	initial := make([]byte, input.ReadInitial)
	if _, err = io.ReadFull(conn, initial); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	result := map[string]any{"initial": initial}
	if input.HalfClose {
		probe := make([]byte, 1)
		_, err = conn.Read(probe)
		if err != io.EOF {
			fmt.Fprintln(os.Stderr, "expected half-close EOF", err)
			os.Exit(1)
		}
		result["read_eof"] = true
	}
	n, err := conn.Write(input.Payload)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	result["write_count"] = n
	// Further writes on a schedule. A write may still succeed locally after
	// the peer stopped reading, so the fixture backend counts what arrived.
	for i := 1; i < input.Repeat; i++ {
		time.Sleep(interval)
		if _, err = conn.Write(input.Payload); err != nil {
			break
		}
	}
	if input.CloseWrite {
		// close_notify over TLS (shutdown over a Unix socket), then keep reading.
		closer, ok := conn.(interface{ CloseWrite() error })
		if !ok {
			fmt.Fprintf(os.Stderr, "%T cannot half-close\n", conn)
			os.Exit(1)
		}
		if err = closer.CloseWrite(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		reply, readErr := io.ReadAll(conn)
		result["reply"] = reply
		if readErr != nil {
			result["read_error"] = readErr.Error()
		}
	} else if !input.HalfClose {
		echo := make([]byte, len(input.Payload))
		if _, err = io.ReadFull(conn, echo); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		result["echo"] = echo
	}
	_ = json.NewEncoder(os.Stdout).Encode(result)
}

// typedCall exercises the official client's own request and response shapes.
func typedCall(client incus.InstanceServer, input Input) {
	result := map[string]any{}
	var err error
	switch input.Action {
	case "server":
		var server *api.Server
		server, _, err = client.GetServer()
		result["server"] = server
	case "certificates":
		result["certificates"], err = client.GetCertificates()
	case "fingerprints":
		result["fingerprints"], err = client.GetCertificateFingerprints()
	case "certificate":
		var certificate *api.Certificate
		var etag string
		certificate, etag, err = client.GetCertificate(input.Fingerprint)
		result["certificate"] = certificate
		result["etag"] = etag
	case "create":
		err = client.CreateCertificate(api.CertificatesPost{CertificatePut: api.CertificatePut{
			Name: input.Name, Type: api.CertificateTypeClient, Certificate: input.Certificate}})
	case "rename":
		var certificate *api.Certificate
		var etag string
		certificate, etag, err = client.GetCertificate(input.Fingerprint)
		if err == nil {
			put := certificate.Writable()
			put.Name = input.Name
			err = client.UpdateCertificate(input.Fingerprint, put, etag)
		}
	case "delete":
		err = client.DeleteCertificate(input.Fingerprint)
	case "list":
		result["instances"], err = client.GetInstanceNames(api.InstanceTypeAny)
	case "access":
		// Project, profile, access, certificate and member selection reads, in
		// the order the shared-client comparison sends them.
		_, err = client.GetProjects()
		if err == nil {
			_, _, err = client.UseProject("p1").GetProfile("default")
		}
		if err == nil {
			_, err = client.GetProjectAccess("p1")
		}
		if err == nil {
			_, err = client.GetCertificates()
		}
		if err == nil {
			_, _, err = client.UseTarget("member-2").GetInstance("c1")
		}
	case "events":
		// The client derives the events WebSocket URL from its remote URL.
		var listener *incus.EventListener
		listener, err = client.GetEvents()
		if err == nil {
			received := make(chan api.Event, 1)
			_, err = listener.AddHandler(nil, func(event api.Event) {
				select {
				case received <- event:
				default:
				}
			})
			if err == nil {
				select {
				case event := <-received:
					result["event"] = event
				case <-time.After(3 * time.Second):
					err = fmt.Errorf("no event received")
				}
			}
			listener.Disconnect()
		}
	case "enroll":
		// As `incus remote add NAME TOKEN` (cmd/incus/remote.go addRemoteFromToken):
		// decode the token, check the served certificate against its
		// fingerprint, then send only the token.
		var token *api.CertificateAddToken
		token, err = localtls.CertificateTokenDecode(input.Token)
		if err == nil {
			result["client_name"] = token.ClientName
			result["addresses"] = token.Addresses
			var served *x509.Certificate
			served, err = localtls.GetRemoteCertificate(input.URL, "")
			if err == nil {
				result["fingerprint_match"] = localtls.CertFingerprint(served) == token.Fingerprint
				err = client.CreateCertificate(api.CertificatesPost{TrustToken: input.Token})
			}
		}
	default:
		err = fmt.Errorf("unknown fixture action")
	}
	if err != nil {
		result["error"] = err.Error()
		if status, ok := api.StatusErrorMatch(err); ok {
			result["error_status"] = status
		}
	}
	if err := json.NewEncoder(os.Stdout).Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
