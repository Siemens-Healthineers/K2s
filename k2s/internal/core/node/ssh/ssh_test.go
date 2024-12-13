// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package ssh_test

import (
	"context"
	"fmt"
	"log/slog"
	"net"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	"github.com/go-logr/logr"
	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"
	"github.com/siemens-healthineers/k2s/internal/core/node/ssh"
	bssh "golang.org/x/crypto/ssh"
	"golang.org/x/term"
)

type sshTestServer struct {
	listener   net.Listener
	cancelChan chan interface{}
	waitGroup  sync.WaitGroup
	sshConfig  *bssh.ServerConfig
}

func TestSshPkg(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "ssh pkg Tests", Label("ci", "ssh"))
}

var _ = BeforeSuite(func() {
	slog.SetDefault(slog.New(logr.ToSlogHandler(GinkgoLogr)))
})

var _ = Describe("ssh pkg", func() {
	Describe("SshKeyPath", Label("unit"), func() {
		It("constructs SSH key path correctly", func() {
			actual := ssh.SshKeyPath("my-dir")

			Expect(actual).To(Equal("my-dir\\k2s\\id_rsa"))
		})
	})

	Describe("Connect", Label("integration"), func() {
		const key = `-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABFwAAAAdzc2gtcn
NhAAAAAwEAAQAAAQEAtNUy6AXUdPtAHkK9EUtwaWgu5yjnGKCIGr/DbocUbLa6iCdRxCik
BSqa+mOobnHfKdTW7dVLxHE4xC72jE021+BhSU9naJL9NxvQMUx3FbeuehGRraaKkwZ89u
Ui1IzrDIkLewa7FboGIHNDraY8WckqMV+XDaUCOjOuUgSH1SRBEZXrN/HOYykLL7ZYKbHP
agZKa7OPeWppNwxWWYrXzaJqIZyNHWJFZDC5jMAcY+8c3rRAYyqX4S9GPT/dZVv+c67hMe
ZmObanF+ULpZg640sHlHbK+ec6zesqwc/IsGTIqyftnIgxFMITOYVxYrGa0BGvG2QNg1+N
tDgzxkFkrwAAA8AasgGEGrIBhAAAAAdzc2gtcnNhAAABAQC01TLoBdR0+0AeQr0RS3BpaC
7nKOcYoIgav8NuhxRstrqIJ1HEKKQFKpr6Y6hucd8p1Nbt1UvEcTjELvaMTTbX4GFJT2do
kv03G9AxTHcVt656EZGtpoqTBnz25SLUjOsMiQt7BrsVugYgc0OtpjxZySoxX5cNpQI6M6
5SBIfVJEERles38c5jKQsvtlgpsc9qBkprs495amk3DFZZitfNomohnI0dYkVkMLmMwBxj
7xzetEBjKpfhL0Y9P91lW/5zruEx5mY5tqcX5QulmDrjSweUdsr55zrN6yrBz8iwZMirJ+
2ciDEUwhM5hXFisZrQEa8bZA2DX420ODPGQWSvAAAAAwEAAQAAAQB96xNGk4CscKPmLmy/
FTvSejRmzImXEXmUvsFUPoVPajIbSt3Z7L7BxjgicLDBL1PJKib7d5IJ2RlBKr6NVdsBmY
HE7aDBJdFixWBEY81sdvnskD1ToOtPk64Cse19+h5WHTu8UCSH7YAEqp6O1Xmiv7w8oyZo
3uTdKE2TWQpItIid4npHjiVmiSQpB5yj4837AXUj3xMdItJEcpgRZov5TgVN8DZdhLu2vK
K/1wDb0t5z3U6BEgnq36VFddKAu2KcyWBlVvC8mh9NYdIlNwk54I40ttw/9Zx5a+qYb1LA
h+0P6I7pkPBtzeF58teCNPcbs3Qt9mUH/St5a/W05EsRAAAAgQCZ5cfjt/0WIR6009gVxf
B28j4AJUpoMHuG9GcrV3hmskf7LZFULwwq//jfExBaQl8n80j0idHrLZmQyiVIm4LO2G7V
dNUBJtYoKI6obMsN8Bf55EhkJrGAjYXTT3sB2wRPIzVJzU9Nk9YyF8wZlWBeCJYreQgCLr
gqp7IRQPy+JwAAAIEA5xbk7s8jExj24Rrdk+QTxq7ref1f3PF+YRlgLQVPgkLBI2k4NgKn
0zV4xFu49s4t7vRNPwZDYHl2FYOzLQhUQWgWRUvlN62ps6FrN/lWAvMECd3x1BgChSCcdy
ojbDpUp8iHnpSGBPuWyeZgAPEn5mNURECyMN6yfGyXl5Y4dAkAAACBAMhTbl6Yp/lnDKMS
NLH27slxZtNANUmBIQTZez3go81SgJKDePRNP7zM7BYVlLXEaBnVlJUSEPyN0k9UtWNBKt
YrmYW4HApwl31L78YoqiRSZIgMIQy42ngwRR1J/X5fcNY8zgMepnKWBHoL1tVIonye/Rxm
XkKXo03REaU7OfD3AAAACHRlc3Qta2V5AQI=
-----END OPENSSH PRIVATE KEY-----
`
		const pubKey = `ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC01TLoBdR0+0AeQr0RS3BpaC7nKOcYoIgav8NuhxRstrqIJ1HEKKQFKpr6Y6hucd8p1Nbt1UvEcTjELvaMTTbX4GFJT2dokv03G9AxTHcVt656EZGtpoqTBnz25SLUjOsMiQt7BrsVugYgc0OtpjxZySoxX5cNpQI6M65SBIfVJEERles38c5jKQsvtlgpsc9qBkprs495amk3DFZZitfNomohnI0dYkVkMLmMwBxj7xzetEBjKpfhL0Y9P91lW/5zruEx5mY5tqcX5QulmDrjSweUdsr55zrN6yrBz8iwZMirJ+2ciDEUwhM5hXFisZrQEa8bZA2DX420ODPGQWSv test-key
`
		const ipAddress = "0.0.0.0"
		const port = 8022

		var tempKeyFile string
		var tempKeyFileBytes []byte

		BeforeEach(func() {
			tempKeyFileBytes = []byte(key)
			tempKeyFile = filepath.Join(GinkgoT().TempDir(), "test-key")

			Expect(os.WriteFile(tempKeyFile, tempKeyFileBytes, os.ModePerm)).To(Succeed())
		})

		When("no SSH server is reachable", func() {
			It("times out within given period", func() {
				clientOptions := ssh.ConnectionOptions{
					IpAddress:  "192.168.1.111",
					Port:       ssh.DefaultPort,
					RemoteUser: "test-user",
					SshKeyPath: tempKeyFile,
					Timeout:    time.Second * 1,
				}

				client, err := ssh.Connect(clientOptions)

				Expect(client).To(BeNil())

				Expect(err).To(MatchError(ContainSubstring("failed to connect via SSH")))
			})
		})

		When("SSH server is reachable", func() {
			var sshServer *sshTestServer

			BeforeEach(func() {
				publicKeyBytes := []byte(pubKey)
				authorizedKeysMap := map[string]bool{}
				for len(publicKeyBytes) > 0 {
					pubKey, _, _, rest, err := bssh.ParseAuthorizedKey(publicKeyBytes)
					Expect(err).ToNot(HaveOccurred())

					authorizedKeysMap[string(pubKey.Marshal())] = true
					publicKeyBytes = rest
				}

				config := &bssh.ServerConfig{
					PublicKeyCallback: func(c bssh.ConnMetadata, pubKey bssh.PublicKey) (*bssh.Permissions, error) {
						if authorizedKeysMap[string(pubKey.Marshal())] {
							return &bssh.Permissions{
								Extensions: map[string]string{
									"pubkey-fp": bssh.FingerprintSHA256(pubKey),
								},
							}, nil
						}
						return nil, fmt.Errorf("unknown public key for %q", c.User())
					},
				}

				private, err := bssh.ParsePrivateKey(tempKeyFileBytes)
				Expect(err).ToNot(HaveOccurred())

				config.AddHostKey(private)
				listenAdress := fmt.Sprintf("%s:%d", ipAddress, port)

				sshServer = startServer(listenAdress, config)
			})

			AfterEach(func() {
				if sshServer != nil {
					sshServer.stop()
				}
			})

			It("it creates an SSH session", func(ctx context.Context) {
				clientOptions := ssh.ConnectionOptions{
					IpAddress:  ipAddress,
					Port:       port,
					RemoteUser: "test-user",
					SshKeyPath: tempKeyFile,
					Timeout:    time.Second * 1,
				}

				client, err := ssh.Connect(clientOptions)
				Expect(err).ToNot(HaveOccurred())

				session, err := client.NewSession()
				Expect(err).ToNot(HaveOccurred())

				Expect(session.Close()).To(Succeed())
				Expect(client.Close()).To(Succeed())
			})
		})
	})
})

func startServer(listenAddress string, config *bssh.ServerConfig) *sshTestServer {
	server := &sshTestServer{
		cancelChan: make(chan any),
		sshConfig:  config,
	}
	listener, err := net.Listen("tcp", listenAddress)
	Expect(err).ToNot(HaveOccurred())

	GinkgoWriter.Println("SSH server listening on", listenAddress)
	server.listener = listener
	server.waitGroup.Add(1)

	go server.run()

	return server
}

func (server *sshTestServer) stop() {
	GinkgoWriter.Println("Stopping server")

	close(server.cancelChan)
	server.listener.Close()
	server.waitGroup.Wait()
}

func (server *sshTestServer) run() {
	defer server.waitGroup.Done()

	for {
		GinkgoWriter.Println("Waiting for connection")

		connection, err := server.listener.Accept()
		if err != nil {
			select {
			case <-server.cancelChan:
				GinkgoWriter.Println("cancel received")
				return
			default:
				GinkgoWriter.Println("failed to accept connection", err)
			}
		} else {
			server.waitGroup.Add(1)
			go func() {
				server.openSshSession(connection)
				server.waitGroup.Done()
			}()
		}
	}
}

func (server *sshTestServer) openSshSession(connection net.Conn) {
	defer connection.Close()

	GinkgoWriter.Println("Connection accepted, starting SSH session")

	sshConnection, chans, reqs, err := bssh.NewServerConn(connection, server.sshConfig)
	Expect(err).ToNot(HaveOccurred())

	GinkgoWriter.Printf("Logged in with key %s\n", sshConnection.Permissions.Extensions["pubkey-fp"])

	var waitGroup sync.WaitGroup
	defer waitGroup.Wait()

	waitGroup.Add(1)
	go func() {
		bssh.DiscardRequests(reqs)
		waitGroup.Done()
	}()

	for newChannel := range chans {
		if newChannel.ChannelType() != "session" {
			newChannel.Reject(bssh.UnknownChannelType, "unknown channel type")
			continue
		}
		channel, requests, err := newChannel.Accept()
		Expect(err).ToNot(HaveOccurred())

		waitGroup.Add(1)
		go func(reqChan <-chan *bssh.Request) {
			for req := range reqChan {
				GinkgoWriter.Println("Request type:", req.Type)
				GinkgoWriter.Println("Request payload:", req.Payload)
				GinkgoWriter.Println("Request payload:", string(req.Payload))

				req.Reply(req.Type == "exec", nil) // accept only exec requests, e.g. via "ssh -n <command>"
			}
			waitGroup.Done()
		}(requests)

		term := term.NewTerminal(channel, "test done") // gets closed immediately, no interactive session

		waitGroup.Add(1)
		go func() {
			defer func() {
				channel.Close()
				waitGroup.Done()
			}()
			for {
				line, err := term.ReadLine()
				if err != nil {
					break
				}
				GinkgoWriter.Println(line)
			}
		}()
	}
}
