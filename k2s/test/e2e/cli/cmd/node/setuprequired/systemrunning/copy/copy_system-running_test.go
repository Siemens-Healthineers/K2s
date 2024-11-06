// SPDX-FileCopyrightText:  © 2024 Siemens Healthineers AG
// SPDX-License-Identifier:   MIT

package copy

import (
	"context"
	"fmt"
	"io/fs"
	"os"
	"path"
	"path/filepath"
	"testing"
	"time"

	. "github.com/onsi/ginkgo/v2"
	. "github.com/onsi/gomega"

	"github.com/siemens-healthineers/k2s/internal/core/setupinfo"
	"github.com/siemens-healthineers/k2s/test/framework"
	"github.com/siemens-healthineers/k2s/test/framework/k2s"
)

type sshExecutor struct {
	ipAddress  string
	remoteUser string
	keyPath    string
	execFunc   func(ctx context.Context, cliPath string, cliArgs ...string) string
}

var suite *framework.K2sTestSuite
var skipWinNodeTests bool

func TestCopy(t *testing.T) {
	RegisterFailHandler(Fail)
	RunSpecs(t, "node copy Acceptance Tests", Label("cli", "node", "copy", "acceptance", "setup-required", "system-running"))
}

var _ = BeforeSuite(func(ctx context.Context) {
	suite = framework.Setup(ctx, framework.SystemMustBeRunning, framework.ClusterTestStepPollInterval(100*time.Millisecond))

	skipWinNodeTests = suite.SetupInfo().SetupConfig.SetupName != setupinfo.SetupNameMultiVMK8s || suite.SetupInfo().SetupConfig.LinuxOnly
})

var _ = AfterSuite(func(ctx context.Context) {
	suite.TearDown(ctx)
})

var _ = Describe("node copy", Ordered, func() {
	Describe("copy to node", func() {
		When("source does not exist", func() {
			DescribeTable("exits with failure", func(ctx context.Context, source string) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "node", "copy", "--ip-addr", "", "-s", source, "-t", "", "-o")

				Expect(output).To(SatisfyAll(
					MatchRegexp("ERROR"),
					MatchRegexp("failed to copy"),
					MatchRegexp("source .+ does not exist"),
				))
			},
				Entry("file not existing", "c:\\non-existent.file"),
				Entry("folder not existing", "c:\\non-existent\\folder\\"),
			)
		})

		When("node is Linux node", Label("linux-node"), func() {
			var nodeIpAddress string
			var localTempDir string

			var remoteTempDirName string
			var remoteTempDir string

			var sshExec *sshExecutor

			BeforeEach(func(ctx context.Context) {
				localTempDir = GinkgoT().TempDir()
				remoteTempDirName = fmt.Sprintf("test_%d/", GinkgoRandomSeed())
				remoteTempDir = "~/" + remoteTempDirName

				nodeIpAddress = k2s.GetControlPlane(suite.SetupInfo().Config.Nodes).IpAddress

				GinkgoWriter.Println("Using control-plane node IP address <", nodeIpAddress, ">")

				sshExec = &sshExecutor{
					ipAddress:  nodeIpAddress,
					remoteUser: "remote",
					keyPath:    "~/.ssh\\kubemaster\\id_rsa",
					execFunc:   suite.Cli().ExecOrFail,
				}

				GinkgoWriter.Println("Creating remote temp dir <", remoteTempDir, ">")

				sshExec.exec(ctx, "mkdir "+remoteTempDir)
			})

			AfterEach(func(ctx context.Context) {
				GinkgoWriter.Println("Removing remote temp dir <", remoteTempDir, ">")

				sshExec.exec(ctx, "rm -rf "+remoteTempDir)
			})

			When("source is a file", func() {
				const sourceFileName = "test.file"
				const sourceFileContent = "This is the test file content.\n"

				var sourceFile string

				BeforeEach(func(ctx context.Context) {
					sourceFile = filepath.Join(localTempDir, sourceFileName)

					Expect(os.WriteFile(sourceFile, []byte(sourceFileContent), fs.ModePerm)).To(Succeed())

					GinkgoWriter.Println("Local test file (source) <", sourceFile, "> written")
				})

				When("target is existing", func() {
					When("target is a file", func() {
						var existingRemoteFile string

						BeforeEach(func(ctx context.Context) {
							existingRemoteFile = path.Join(remoteTempDir, sourceFileName)

							GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

							sshExec.exec(ctx, "echo 'existing content' > "+existingRemoteFile)
						})

						It("overwrites the existing file", func(ctx context.Context) {
							targetFile := existingRemoteFile

							output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o")

							Expect(output).To(MatchRegexp("'copy' done"))

							content := sshExec.exec(ctx, "cat "+targetFile)

							Expect(content).To(Equal(sourceFileContent))
						})

						When("target is file name only", func() {
							BeforeEach(func(ctx context.Context) {
								existingRemoteFile = sourceFileName

								GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

								sshExec.exec(ctx, "echo 'existing content' > "+existingRemoteFile)
							})

							AfterEach(func(ctx context.Context) {
								GinkgoWriter.Println("Removing file <", existingRemoteFile, ">")

								sshExec.exec(ctx, "rm -rf "+existingRemoteFile)
							})

							It("overwrites existing file in home dir", func(ctx context.Context) {
								targetFile := sourceFileName

								output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o")

								Expect(output).To(MatchRegexp("'copy' done"))

								content := sshExec.exec(ctx, "cat "+targetFile)

								Expect(content).To(Equal(sourceFileContent))
							})
						})
					})

					When("target is a folder", func() {
						When("file with same name exists in target", func() {
							var existingRemoteFile string

							BeforeEach(func(ctx context.Context) {
								existingRemoteFile = path.Join(remoteTempDir, sourceFileName)

								GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

								sshExec.exec(ctx, "echo 'existing content' > "+existingRemoteFile)
							})

							It("overwrites the existing file", func(ctx context.Context) {
								targetFolder := remoteTempDir

								output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o")

								Expect(output).To(MatchRegexp("'copy' done"))

								content := sshExec.exec(ctx, "cat "+existingRemoteFile)

								Expect(content).To(Equal(sourceFileContent))
							})

							When("target is tilde (~/) only", func() {
								BeforeEach(func(ctx context.Context) {
									existingRemoteFile = "~/" + sourceFileName

									GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

									sshExec.exec(ctx, "echo 'existing content' > "+existingRemoteFile)
								})

								AfterEach(func(ctx context.Context) {
									GinkgoWriter.Println("Removing file <", existingRemoteFile, ">")

									sshExec.exec(ctx, "rm -rf "+existingRemoteFile)
								})

								It("overwrites the existing file in the home dir", func(ctx context.Context) {
									targetFolder := "~/"

									output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o")

									Expect(output).To(MatchRegexp("'copy' done"))

									content := sshExec.exec(ctx, "cat "+existingRemoteFile)

									Expect(content).To(Equal(sourceFileContent))
								})
							})
						})

						When("file with same name does not exist in target", func() {
							It("copies the file to target", func(ctx context.Context) {
								targetFolder := remoteTempDir
								expectedTargetFile := path.Join(remoteTempDir, sourceFileName)

								output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o")

								Expect(output).To(MatchRegexp("'copy' done"))

								content := sshExec.exec(ctx, "cat "+expectedTargetFile)

								Expect(content).To(Equal(sourceFileContent))
							})

							When("target is tilde (~/) only", func() {
								var expectedRemoteFile string

								BeforeEach(func() {
									expectedRemoteFile = "~/" + sourceFileName
								})

								AfterEach(func(ctx context.Context) {
									GinkgoWriter.Println("Removing file <", expectedRemoteFile, ">")

									sshExec.exec(ctx, "rm -rf "+expectedRemoteFile)
								})

								It("copies the file to home dir", func(ctx context.Context) {
									targetFolder := "~/"

									output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o")

									Expect(output).To(MatchRegexp("'copy' done"))

									content := sshExec.exec(ctx, "cat "+expectedRemoteFile)

									Expect(content).To(Equal(sourceFileContent))
								})
							})
						})
					})
				})

				When("target is not existing", func() {
					When("target parent folder is existing", func() {
						It("creates the target file and copies the content", func(ctx context.Context) {
							targetFile := path.Join(remoteTempDir, sourceFileName)

							output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o")

							Expect(output).To(MatchRegexp("'copy' done"))

							content := sshExec.exec(ctx, "cat "+targetFile)

							Expect(content).To(Equal(sourceFileContent))
						})
					})

					When("target parent folder is not existing", func() {
						It("exits with failure", func(ctx context.Context) {
							targetFile := path.Join(remoteTempDir, "non-existent", sourceFileName)

							output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o")

							Expect(output).To(SatisfyAll(
								MatchRegexp("ERROR"),
								MatchRegexp("failed to copy"),
								MatchRegexp("parent .+ not existing"),
							))
						})
					})

					When("target is file name only", func() {
						var expectedRemoteFile string

						BeforeEach(func() {
							expectedRemoteFile = sourceFileName
						})

						AfterEach(func(ctx context.Context) {
							GinkgoWriter.Println("Removing file <", expectedRemoteFile, ">")

							sshExec.exec(ctx, "rm -rf "+expectedRemoteFile)
						})

						It("copies the file to home dir", func(ctx context.Context) {
							targetFile := sourceFileName

							output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o")

							Expect(output).To(MatchRegexp("'copy' done"))

							content := sshExec.exec(ctx, "cat "+expectedRemoteFile)

							Expect(content).To(Equal(sourceFileContent))
						})
					})
				})
			})

			When("source is a folder", func() {
				const sourceFolderName = "test-folder"
				const sourceSubFolderName = "test-sub-folder"

				var sourceFileInfos = []struct {
					name      string
					subFolder string
					content   string
				}{
					{name: "test-1-file", subFolder: "", content: "test-content-1\n"},
					{name: "test-2-file", subFolder: sourceSubFolderName, content: "test-content-2\n"},
					{name: "test-3-file", subFolder: "", content: "test-content-3\n"},
				}

				var sourceFolder string

				BeforeEach(func(ctx context.Context) {
					sourceFolder = filepath.Join(localTempDir, sourceFolderName)

					GinkgoWriter.Println("Creating local source folder <", sourceFolder, ">")
					Expect(os.MkdirAll(sourceFolder, fs.ModePerm)).To(Succeed())

					for _, fileInfo := range sourceFileInfos {
						dir := sourceFolder

						if fileInfo.subFolder != "" {
							dir = filepath.Join(sourceFolder, fileInfo.subFolder)

							GinkgoWriter.Println("Creating local source sub folder <", dir, ">")
							Expect(os.MkdirAll(dir, fs.ModePerm)).To(Succeed())
						}

						filePath := filepath.Join(dir, fileInfo.name)

						GinkgoWriter.Println("Writing local source file <", filePath, ">")
						Expect(os.WriteFile(filePath, []byte(fileInfo.content), fs.ModePerm)).To(Succeed())
					}
				})

				When("target is existing", func() {
					When("target is a file", func() {
						var existingRemoteFile string

						BeforeEach(func(ctx context.Context) {
							existingRemoteFile = path.Join(remoteTempDir, "some-file")

							GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

							sshExec.exec(ctx, "echo 'existing content' > "+existingRemoteFile)
						})

						It("exits with failure", func(ctx context.Context) {
							targetFile := existingRemoteFile

							output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFile, "-o")

							Expect(output).To(SatisfyAll(
								MatchRegexp("ERROR"),
								MatchRegexp("failed to copy"),
								MatchRegexp("target .+ is a file"),
							))
						})
					})

					When("target is a folder", func() {
						When("source folder name exists in target", func() {
							var existingRemoteFolder string

							BeforeEach(func(ctx context.Context) {
								existingRemoteFolder = path.Join(remoteTempDir, sourceFolderName)

								GinkgoWriter.Println("Creating remote folder <", existingRemoteFolder, ">")

								sshExec.exec(ctx, "mkdir "+existingRemoteFolder)
							})

							It("copies contents of source folder to existing folder in target dir", func(ctx context.Context) {
								targetFolder := remoteTempDir

								output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o")

								Expect(output).To(MatchRegexp("'copy' done"))

								for _, fileInfo := range sourceFileInfos {
									remotePath := path.Join(existingRemoteFolder, fileInfo.subFolder, fileInfo.name)
									content := sshExec.exec(ctx, "cat "+remotePath)

									Expect(content).To(Equal(fileInfo.content))
								}
							})

							When("folder with same name contains files with same name", func() {
								BeforeEach(func(ctx context.Context) {
									for _, fileInfo := range sourceFileInfos {
										dir := existingRemoteFolder

										if fileInfo.subFolder != "" {
											dir = path.Join(dir, fileInfo.subFolder)

											GinkgoWriter.Println("Creating remote target sub folder <", dir, ">")
											sshExec.exec(ctx, "mkdir "+dir)
										}

										filePath := path.Join(dir, fileInfo.name)

										GinkgoWriter.Println("Writing remote target file <", filePath, ">")
										sshExec.exec(ctx, "echo 'existing content' > "+filePath)
									}
								})

								It("copies contents of source folder to existing folder in target dir, overwriting existing files", func(ctx context.Context) {
									targetFolder := remoteTempDir

									output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o")

									Expect(output).To(MatchRegexp("'copy' done"))

									for _, fileInfo := range sourceFileInfos {
										remotePath := path.Join(existingRemoteFolder, fileInfo.subFolder, fileInfo.name)
										content := sshExec.exec(ctx, "cat "+remotePath)

										Expect(content).To(Equal(fileInfo.content))
									}
								})
							})
						})

						When("source folder name does not exist in target", func() {
							It("copies the folder to target", func(ctx context.Context) {
								targetFolder := remoteTempDir

								output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o")

								Expect(output).To(MatchRegexp("'copy' done"))

								for _, fileInfo := range sourceFileInfos {
									remotePath := path.Join(remoteTempDir, sourceFolderName, fileInfo.subFolder, fileInfo.name)
									content := sshExec.exec(ctx, "cat "+remotePath)

									Expect(content).To(Equal(fileInfo.content))
								}
							})
						})
					})
				})

				When("target is not existing", func() {
					When("target parent folder is existing", func() {
						It("creates target dir and copies contents of source folder", func(ctx context.Context) {
							targetFolder := path.Join(remoteTempDir, sourceFolderName)

							output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o")

							Expect(output).To(MatchRegexp("'copy' done"))

							for _, fileInfo := range sourceFileInfos {
								remotePath := path.Join(targetFolder, fileInfo.subFolder, fileInfo.name)
								content := sshExec.exec(ctx, "cat "+remotePath)

								Expect(content).To(Equal(fileInfo.content))
							}
						})
					})

					When("target parent folder is not existing", func() {
						It("exits with failure", func(ctx context.Context) {
							targetFolder := path.Join(remoteTempDir, "non-existent-parent", sourceFolderName)

							output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o")

							Expect(output).To(SatisfyAll(
								MatchRegexp("ERROR"),
								MatchRegexp("failed to copy"),
								MatchRegexp("remote parent not existing"),
							))
						})
					})
				})
			})
		})

		When("node is Windows node", Label("windows-node"), func() {
			const remoteUser = "administrator"

			var nodeIpAddress string
			var localTempDir string

			var remoteTempDirName string
			var remoteTempDir string

			var sshExec *sshExecutor

			BeforeEach(func(ctx context.Context) {
				if skipWinNodeTests {
					Skip("Windows node tests are skipped")
				}

				localTempDir = GinkgoT().TempDir()
				remoteTempDirName = fmt.Sprintf("test_%d/", GinkgoRandomSeed())
				remoteTempDir = filepath.Join("C:\\Users", remoteUser, remoteTempDirName)

				nodeIpAddress = k2s.GetWindowsNode(suite.SetupInfo().Config.Nodes).IpAddress

				GinkgoWriter.Println("Using windows node IP address <", nodeIpAddress, ">")

				sshExec = &sshExecutor{
					ipAddress:  nodeIpAddress,
					remoteUser: remoteUser,
					keyPath:    "~/.ssh\\kubemaster\\id_rsa",
					execFunc:   suite.Cli().ExecOrFail,
				}

				GinkgoWriter.Println("Creating remote temp dir <", remoteTempDir, ">")

				sshExec.exec(ctx, "mkdir "+remoteTempDir)
			})

			AfterEach(func(ctx context.Context) {
				if skipWinNodeTests {
					Skip("Windows node tests are skipped")
				}

				GinkgoWriter.Println("Removing remote temp dir <", remoteTempDir, ">")

				sshExec.exec(ctx, "rd /s /q "+remoteTempDir)
			})

			When("source is a file", func() {
				const sourceFileName = "test.file"
				const sourceFileContent = "This is the test file content.\r\n"

				var sourceFile string

				BeforeEach(func(ctx context.Context) {
					sourceFile = filepath.Join(localTempDir, sourceFileName)

					Expect(os.WriteFile(sourceFile, []byte(sourceFileContent), fs.ModePerm)).To(Succeed())

					GinkgoWriter.Println("Local test file (source) <", sourceFile, "> written")
				})

				When("target is existing", func() {
					When("target is a file", func() {
						var existingRemoteFile string

						BeforeEach(func(ctx context.Context) {
							existingRemoteFile = filepath.Join(remoteTempDir, sourceFileName)

							GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

							sshExec.exec(ctx, "echo 'existing content' > "+existingRemoteFile)
						})

						It("overwrites the existing file", func(ctx context.Context) {
							targetFile := existingRemoteFile

							output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(MatchRegexp("'copy' done"))

							content := sshExec.exec(ctx, "more "+targetFile)

							Expect(content).To(Equal(sourceFileContent))
						})

						When("target is file name only", func() {
							BeforeEach(func(ctx context.Context) {
								existingRemoteFile = sourceFileName

								GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

								sshExec.exec(ctx, "echo 'existing content' > "+existingRemoteFile)
							})

							AfterEach(func(ctx context.Context) {
								GinkgoWriter.Println("Removing file <", existingRemoteFile, ">")

								sshExec.exec(ctx, "del "+existingRemoteFile)
							})

							It("overwrites existing file in home dir", func(ctx context.Context) {
								targetFile := sourceFileName

								output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'copy' done"))

								content := sshExec.exec(ctx, "more "+targetFile)

								Expect(content).To(Equal(sourceFileContent))
							})
						})
					})

					When("target is a folder", func() {
						When("file with same name exists in target", func() {
							var existingRemoteFile string

							BeforeEach(func(ctx context.Context) {
								existingRemoteFile = filepath.Join(remoteTempDir, sourceFileName)

								GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

								sshExec.exec(ctx, "echo 'existing content' > "+existingRemoteFile)
							})

							It("overwrites the existing file", func(ctx context.Context) {
								targetFolder := remoteTempDir

								output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'copy' done"))

								content := sshExec.exec(ctx, "more "+existingRemoteFile)

								Expect(content).To(Equal(sourceFileContent))
							})

							When("target is tilde (~\\) only", func() {
								BeforeEach(func(ctx context.Context) {
									existingRemoteFile = sourceFileName

									GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

									sshExec.exec(ctx, "echo 'existing content' > "+existingRemoteFile)
								})

								AfterEach(func(ctx context.Context) {
									GinkgoWriter.Println("Removing file <", existingRemoteFile, ">")

									sshExec.exec(ctx, "del "+existingRemoteFile)
								})

								It("overwrites the existing file in the home dir", func(ctx context.Context) {
									targetFolder := "~\\"

									output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'copy' done"))

									content := sshExec.exec(ctx, "more "+existingRemoteFile)

									Expect(content).To(Equal(sourceFileContent))
								})
							})
						})

						When("file with same name does not exist in target", func() {
							It("copies the file to target", func(ctx context.Context) {
								targetFolder := remoteTempDir
								expectedTargetFile := filepath.Join(remoteTempDir, sourceFileName)

								output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'copy' done"))

								content := sshExec.exec(ctx, "more "+expectedTargetFile)

								Expect(content).To(Equal(sourceFileContent))
							})

							When("target is tilde (~\\) only", func() {
								var expectedRemoteFile string

								BeforeEach(func() {
									expectedRemoteFile = sourceFileName
								})

								AfterEach(func(ctx context.Context) {
									GinkgoWriter.Println("Removing file <", expectedRemoteFile, ">")

									sshExec.exec(ctx, "del "+expectedRemoteFile)
								})

								It("copies the file to home dir", func(ctx context.Context) {
									targetFolder := "~\\"

									output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'copy' done"))

									content := sshExec.exec(ctx, "more "+expectedRemoteFile)

									Expect(content).To(Equal(sourceFileContent))
								})
							})
						})
					})
				})

				When("target is not existing", func() {
					When("target parent folder is existing", func() {
						It("creates the target file and copies the content", func(ctx context.Context) {
							targetFile := filepath.Join(remoteTempDir, sourceFileName)

							output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(MatchRegexp("'copy' done"))

							content := sshExec.exec(ctx, "more "+targetFile)

							Expect(content).To(Equal(sourceFileContent))
						})
					})

					When("target parent folder is not existing", func() {
						It("exits with failure", func(ctx context.Context) {
							targetFile := filepath.Join(remoteTempDir, "non-existent", sourceFileName)

							output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(SatisfyAll(
								MatchRegexp("ERROR"),
								MatchRegexp("failed to copy"),
								MatchRegexp("parent .+ not existing"),
							))
						})
					})

					When("target is file name only", func() {
						var expectedRemoteFile string

						BeforeEach(func() {
							expectedRemoteFile = sourceFileName
						})

						AfterEach(func(ctx context.Context) {
							GinkgoWriter.Println("Removing file <", expectedRemoteFile, ">")

							sshExec.exec(ctx, "del "+expectedRemoteFile)
						})

						It("copies the file to home dir", func(ctx context.Context) {
							targetFile := sourceFileName

							output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(MatchRegexp("'copy' done"))

							content := sshExec.exec(ctx, "more "+expectedRemoteFile)

							Expect(content).To(Equal(sourceFileContent))
						})
					})
				})
			})

			When("source is a folder", func() {
				const sourceFolderName = "test-folder"
				const sourceSubFolderName = "test-sub-folder"

				var sourceFileInfos = []struct {
					name      string
					subFolder string
					content   string
				}{
					{name: "test-1-file", subFolder: "", content: "test-content-1\r\n"},
					{name: "test-2-file", subFolder: sourceSubFolderName, content: "test-content-2\r\n"},
					{name: "test-3-file", subFolder: "", content: "test-content-3\r\n"},
				}

				var sourceFolder string

				BeforeEach(func(ctx context.Context) {
					sourceFolder = filepath.Join(localTempDir, sourceFolderName)

					GinkgoWriter.Println("Creating local source folder <", sourceFolder, ">")
					Expect(os.MkdirAll(sourceFolder, fs.ModePerm)).To(Succeed())

					for _, fileInfo := range sourceFileInfos {
						dir := sourceFolder

						if fileInfo.subFolder != "" {
							dir = filepath.Join(sourceFolder, fileInfo.subFolder)

							GinkgoWriter.Println("Creating local source sub folder <", dir, ">")
							Expect(os.MkdirAll(dir, fs.ModePerm)).To(Succeed())
						}

						filePath := filepath.Join(dir, fileInfo.name)

						GinkgoWriter.Println("Writing local source file <", filePath, ">")
						Expect(os.WriteFile(filePath, []byte(fileInfo.content), fs.ModePerm)).To(Succeed())
					}
				})

				When("target is existing", func() {
					When("target is a file", func() {
						var existingRemoteFile string

						BeforeEach(func(ctx context.Context) {
							existingRemoteFile = filepath.Join(remoteTempDir, "some-file")

							GinkgoWriter.Println("Creating remote file <", existingRemoteFile, ">")

							sshExec.exec(ctx, "echo 'existing content' > "+existingRemoteFile)
						})

						It("exits with failure", func(ctx context.Context) {
							targetFile := existingRemoteFile

							output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFile, "-o", "-u", remoteUser)

							Expect(output).To(SatisfyAll(
								MatchRegexp("ERROR"),
								MatchRegexp("failed to copy"),
								MatchRegexp("target .+ is a file"),
							))
						})
					})

					When("target is a folder", func() {
						When("source folder name exists in target", func() {
							var existingRemoteFolder string

							BeforeEach(func(ctx context.Context) {
								existingRemoteFolder = filepath.Join(remoteTempDir, sourceFolderName)

								GinkgoWriter.Println("Creating remote folder <", existingRemoteFolder, ">")

								sshExec.exec(ctx, "mkdir "+existingRemoteFolder)
							})

							It("copies contents of source folder to existing folder in target dir", func(ctx context.Context) {
								targetFolder := remoteTempDir

								output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'copy' done"))

								for _, fileInfo := range sourceFileInfos {
									remotePath := filepath.Join(existingRemoteFolder, fileInfo.subFolder, fileInfo.name)
									content := sshExec.exec(ctx, "more "+remotePath)

									Expect(content).To(Equal(fileInfo.content))
								}
							})

							When("folder with same name contains files with same name", func() {
								BeforeEach(func(ctx context.Context) {
									for _, fileInfo := range sourceFileInfos {
										dir := existingRemoteFolder

										if fileInfo.subFolder != "" {
											dir = filepath.Join(dir, fileInfo.subFolder)

											GinkgoWriter.Println("Creating remote target sub folder <", dir, ">")
											sshExec.exec(ctx, "mkdir "+dir)
										}

										filePath := filepath.Join(dir, fileInfo.name)

										GinkgoWriter.Println("Writing remote target file <", filePath, ">")
										sshExec.exec(ctx, "echo 'existing content' > "+filePath)
									}
								})

								It("copies contents of source folder to existing folder in target dir, overwriting existing files", func(ctx context.Context) {
									targetFolder := remoteTempDir

									output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'copy' done"))

									for _, fileInfo := range sourceFileInfos {
										remotePath := filepath.Join(existingRemoteFolder, fileInfo.subFolder, fileInfo.name)
										content := sshExec.exec(ctx, "more "+remotePath)

										Expect(content).To(Equal(fileInfo.content))
									}
								})
							})
						})

						When("source folder name does not exist in target", func() {
							It("copies the folder to target", func(ctx context.Context) {
								targetFolder := remoteTempDir

								output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'copy' done"))

								for _, fileInfo := range sourceFileInfos {
									remotePath := filepath.Join(remoteTempDir, sourceFolderName, fileInfo.subFolder, fileInfo.name)
									content := sshExec.exec(ctx, "more "+remotePath)

									Expect(content).To(Equal(fileInfo.content))
								}
							})
						})
					})
				})

				When("target is not existing", func() {
					When("target parent folder is existing", func() {
						It("creates target dir and copies contents of source folder", func(ctx context.Context) {
							targetFolder := filepath.Join(remoteTempDir, sourceFolderName)

							output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

							Expect(output).To(MatchRegexp("'copy' done"))

							for _, fileInfo := range sourceFileInfos {
								remotePath := filepath.Join(targetFolder, fileInfo.subFolder, fileInfo.name)
								content := sshExec.exec(ctx, "more "+remotePath)

								Expect(content).To(Equal(fileInfo.content))
							}
						})
					})

					When("target parent folder is not existing", func() {
						It("exits with failure", func(ctx context.Context) {
							targetFolder := filepath.Join(remoteTempDir, "non-existent-parent", sourceFolderName)

							output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-u", remoteUser)

							Expect(output).To(SatisfyAll(
								MatchRegexp("ERROR"),
								MatchRegexp("failed to copy"),
								MatchRegexp("remote parent not existing"),
							))
						})
					})
				})
			})
		})
	})

	Describe("copy from node", func() {
		When("node is Linux node", Label("linux-node"), func() {
			const remoteUser = "remote"

			var nodeIpAddress string

			BeforeEach(func(ctx context.Context) {
				nodeIpAddress = k2s.GetControlPlane(suite.SetupInfo().Config.Nodes).IpAddress

				GinkgoWriter.Println("Using control-plane node IP address <", nodeIpAddress, ">")
			})

			When("source does not exist", func() {
				DescribeTable("exits with failure", func(ctx context.Context, source string) {
					output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "node", "copy", "--ip-addr", nodeIpAddress, "-s", source, "-t", "~\\", "-o", "-r", "-u", remoteUser)

					Expect(output).To(SatisfyAll(
						MatchRegexp("ERROR"),
						MatchRegexp("failed to copy"),
						MatchRegexp("source .+ does not exist"),
					))
				},
					Entry("file not existing", "~/non-existent.file"),
					Entry("folder not existing", "~/non-existent/folder/"),
				)
			})

			When("source exists", func() {
				var localTempDir string

				var remoteTempDirName string
				var remoteTempDir string

				var sshExec *sshExecutor

				BeforeEach(func(ctx context.Context) {
					localTempDir = GinkgoT().TempDir()
					remoteTempDirName = fmt.Sprintf("test_%d/", GinkgoRandomSeed())
					remoteTempDir = "~/" + remoteTempDirName

					sshExec = &sshExecutor{
						ipAddress:  nodeIpAddress,
						remoteUser: "remote",
						keyPath:    "~/.ssh\\kubemaster\\id_rsa",
						execFunc:   suite.Cli().ExecOrFail,
					}

					GinkgoWriter.Println("Creating remote temp dir <", remoteTempDir, ">")

					sshExec.exec(ctx, "mkdir "+remoteTempDir)
				})

				AfterEach(func(ctx context.Context) {
					GinkgoWriter.Println("Removing remote temp dir <", remoteTempDir, ">")

					sshExec.exec(ctx, "rm -rf "+remoteTempDir)
				})

				When("source is a file", func() {
					const sourceFileName = "test.file"
					const sourceFileContent = "This is the test file content."

					var sourceFile string

					BeforeEach(func(ctx context.Context) {
						sourceFile = path.Join(remoteTempDir, sourceFileName)

						GinkgoWriter.Println("Creating remote file <", sourceFile, ">")
						sshExec.exec(ctx, "echo -n '"+sourceFileContent+"' > "+sourceFile)
						GinkgoWriter.Println("Remote file <", sourceFile, "> created")
					})

					When("target is existing", func() {
						When("target is a file", func() {
							var existingLocalFile string

							BeforeEach(func(ctx context.Context) {
								existingLocalFile = filepath.Join(localTempDir, sourceFileName)

								GinkgoWriter.Println("Creating local file <", existingLocalFile, ">")
								Expect(os.WriteFile(existingLocalFile, []byte("existing content"), fs.ModePerm)).To(Succeed())
								GinkgoWriter.Println("Local file <", existingLocalFile, "> created")
							})

							It("overwrites the existing file", func(ctx context.Context) {
								targetFile := existingLocalFile

								output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-r", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'copy' done"))

								content, err := os.ReadFile(targetFile)

								Expect(err).ToNot(HaveOccurred())
								Expect(string(content)).To(Equal(sourceFileContent))
							})
						})

						When("target is a folder", func() {
							When("file with same name exists in target", func() {
								var existingLocalFile string

								BeforeEach(func(ctx context.Context) {
									existingLocalFile = filepath.Join(localTempDir, sourceFileName)

									GinkgoWriter.Println("Creating local file <", existingLocalFile, ">")
									Expect(os.WriteFile(existingLocalFile, []byte("existing content"), fs.ModePerm)).To(Succeed())
									GinkgoWriter.Println("Local file <", existingLocalFile, "> created")
								})

								It("overwrites the existing file", func(ctx context.Context) {
									targetFolder := localTempDir

									output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'copy' done"))

									content, err := os.ReadFile(existingLocalFile)

									Expect(err).ToNot(HaveOccurred())
									Expect(string(content)).To(Equal(sourceFileContent))
								})

								When("target is tilde (~\\) only", func() {
									BeforeEach(func(ctx context.Context) {
										localHomeDir, err := os.UserHomeDir()
										Expect(err).ToNot(HaveOccurred())

										existingLocalFile = filepath.Join(localHomeDir, sourceFileName)

										GinkgoWriter.Println("Creating local file <", existingLocalFile, ">")
										Expect(os.WriteFile(existingLocalFile, []byte("existing content"), fs.ModePerm)).To(Succeed())
										GinkgoWriter.Println("Local file <", existingLocalFile, "> created")
									})

									AfterEach(func(ctx context.Context) {
										GinkgoWriter.Println("Removing local file <", existingLocalFile, ">")
										Expect(os.Remove(existingLocalFile)).To(Succeed())
										GinkgoWriter.Println("Local file <", existingLocalFile, "> removed")
									})

									It("overwrites the existing file in the home dir", func(ctx context.Context) {
										targetFolder := "~\\"

										output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

										Expect(output).To(MatchRegexp("'copy' done"))

										content, err := os.ReadFile(existingLocalFile)

										Expect(err).ToNot(HaveOccurred())
										Expect(string(content)).To(Equal(sourceFileContent))
									})
								})
							})

							When("file with same name does not exist in target", func() {
								It("copies the file to target", func(ctx context.Context) {
									targetFolder := localTempDir
									expectedTargetFile := filepath.Join(localTempDir, sourceFileName)

									output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'copy' done"))

									content, err := os.ReadFile(expectedTargetFile)

									Expect(err).ToNot(HaveOccurred())
									Expect(string(content)).To(Equal(sourceFileContent))
								})

								When("target is tilde (~\\) only", func() {
									var expectedTargetFile string

									BeforeEach(func() {
										localHomeDir, err := os.UserHomeDir()
										Expect(err).ToNot(HaveOccurred())

										expectedTargetFile = filepath.Join(localHomeDir, sourceFileName)
									})

									AfterEach(func(ctx context.Context) {
										GinkgoWriter.Println("Removing local file <", expectedTargetFile, ">")
										Expect(os.Remove(expectedTargetFile)).To(Succeed())
										GinkgoWriter.Println("Local file <", expectedTargetFile, "> removed")
									})

									It("copies the file to home dir", func(ctx context.Context) {
										targetFolder := "~\\"

										output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

										Expect(output).To(MatchRegexp("'copy' done"))

										content, err := os.ReadFile(expectedTargetFile)

										Expect(err).ToNot(HaveOccurred())
										Expect(string(content)).To(Equal(sourceFileContent))
									})
								})
							})
						})
					})

					When("target is not existing", func() {
						When("target parent folder is existing", func() {
							It("creates the target file and copies the content", func(ctx context.Context) {
								targetFile := filepath.Join(localTempDir, sourceFileName)

								output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-r", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'copy' done"))

								content, err := os.ReadFile(targetFile)

								Expect(err).ToNot(HaveOccurred())
								Expect(string(content)).To(Equal(sourceFileContent))
							})
						})

						When("target parent folder is not existing", func() {
							It("exits with failure", func(ctx context.Context) {
								targetFile := filepath.Join(localTempDir, "non-existent", sourceFileName)

								output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFile, "-t", targetFile, "-o", "-r", "-u", remoteUser)

								Expect(output).To(SatisfyAll(
									MatchRegexp("ERROR"),
									MatchRegexp("failed to copy"),
									MatchRegexp("parent .+ not existing"),
								))
							})
						})
					})
				})

				When("source is a folder", func() {
					const sourceFolderName = "test-folder"
					const sourceSubFolderName = "test-sub-folder"

					var sourceFileInfos = []struct {
						name      string
						subFolder string
						content   string
					}{
						{name: "test-1-file", subFolder: "", content: "test-content-1"},
						{name: "test-2-file", subFolder: sourceSubFolderName, content: "test-content-2"},
						{name: "test-3-file", subFolder: "", content: "test-content-3"},
					}

					var sourceFolder string

					BeforeEach(func(ctx context.Context) {
						sourceFolder = path.Join(remoteTempDir, sourceFolderName)

						GinkgoWriter.Println("Creating remote source folder <", sourceFolder, ">")
						sshExec.exec(ctx, "mkdir "+sourceFolder)

						for _, fileInfo := range sourceFileInfos {
							dir := sourceFolder

							if fileInfo.subFolder != "" {
								dir = path.Join(dir, fileInfo.subFolder)

								GinkgoWriter.Println("Creating remote source sub folder <", dir, ">")
								sshExec.exec(ctx, "mkdir "+dir)
							}

							filePath := path.Join(dir, fileInfo.name)

							GinkgoWriter.Println("Writing remote source file <", filePath, ">")
							sshExec.exec(ctx, "echo -n '"+fileInfo.content+"' > "+filePath)
						}
					})

					When("target is existing", func() {
						When("target is a file", func() {
							var existingLocalFile string

							BeforeEach(func(ctx context.Context) {
								existingLocalFile = filepath.Join(localTempDir, "some-file")

								GinkgoWriter.Println("Creating local file <", existingLocalFile, ">")
								Expect(os.WriteFile(existingLocalFile, []byte("existing content"), fs.ModePerm)).To(Succeed())
								GinkgoWriter.Println("Local file <", existingLocalFile, "> created")
							})

							It("exits with failure", func(ctx context.Context) {
								targetFile := existingLocalFile

								output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFile, "-o", "-r", "-u", remoteUser)

								Expect(output).To(SatisfyAll(
									MatchRegexp("ERROR"),
									MatchRegexp("failed to copy"),
									MatchRegexp("target .+ is a file"),
								))
							})
						})

						When("target is a folder", func() {
							When("source folder name exists in target", func() {
								var existingLocalFolder string

								BeforeEach(func(ctx context.Context) {
									existingLocalFolder = filepath.Join(localTempDir, sourceFolderName)

									GinkgoWriter.Println("Creating local folder <", existingLocalFolder, ">")

									Expect(os.Mkdir(existingLocalFolder, fs.ModePerm)).To(Succeed())
								})

								It("copies contents of source folder to existing folder in target dir", func(ctx context.Context) {
									targetFolder := localTempDir

									output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'copy' done"))

									for _, fileInfo := range sourceFileInfos {
										localPath := filepath.Join(existingLocalFolder, fileInfo.subFolder, fileInfo.name)
										content, err := os.ReadFile(localPath)

										Expect(err).ToNot(HaveOccurred())
										Expect(string(content)).To(Equal(fileInfo.content))
									}
								})

								When("folder with same name contains files with same name", func() {
									BeforeEach(func(ctx context.Context) {
										for _, fileInfo := range sourceFileInfos {
											dir := existingLocalFolder

											if fileInfo.subFolder != "" {
												dir = filepath.Join(dir, fileInfo.subFolder)

												GinkgoWriter.Println("Creating local target sub folder <", dir, ">")
												Expect(os.MkdirAll(dir, fs.ModePerm)).To(Succeed())
											}

											filePath := filepath.Join(dir, fileInfo.name)

											GinkgoWriter.Println("Writing local target file <", filePath, ">")
											Expect(os.WriteFile(filePath, []byte("existing content"), fs.ModePerm)).To(Succeed())
										}
									})

									It("copies contents of source folder to existing folder in target dir, overwriting existing files", func(ctx context.Context) {
										targetFolder := localTempDir

										output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

										Expect(output).To(MatchRegexp("'copy' done"))

										for _, fileInfo := range sourceFileInfos {
											localPath := filepath.Join(existingLocalFolder, fileInfo.subFolder, fileInfo.name)
											content, err := os.ReadFile(localPath)

											Expect(err).ToNot(HaveOccurred())
											Expect(string(content)).To(Equal(fileInfo.content))
										}
									})
								})
							})

							When("source folder name does not exist in target", func() {
								It("copies the folder to target", func(ctx context.Context) {
									targetFolder := localTempDir

									output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

									Expect(output).To(MatchRegexp("'copy' done"))

									for _, fileInfo := range sourceFileInfos {
										localPath := filepath.Join(localTempDir, sourceFolderName, fileInfo.subFolder, fileInfo.name)
										content, err := os.ReadFile(localPath)

										Expect(err).ToNot(HaveOccurred())
										Expect(string(content)).To(Equal(fileInfo.content))
									}
								})
							})
						})
					})

					When("target is not existing", func() {
						When("target parent folder is existing", func() {
							It("creates target dir and copies contents of source folder", func(ctx context.Context) {
								targetFolder := filepath.Join(localTempDir, sourceFolderName)

								output := suite.K2sCli().Run(ctx, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

								Expect(output).To(MatchRegexp("'copy' done"))

								for _, fileInfo := range sourceFileInfos {
									localPath := filepath.Join(targetFolder, fileInfo.subFolder, fileInfo.name)
									content, err := os.ReadFile(localPath)

									Expect(err).ToNot(HaveOccurred())
									Expect(string(content)).To(Equal(fileInfo.content))
								}
							})
						})

						When("target parent folder is not existing", func() {
							It("exits with failure", func(ctx context.Context) {
								targetFolder := filepath.Join(localTempDir, "non-existent-parent", sourceFolderName)

								output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "node", "copy", "--ip-addr", nodeIpAddress, "-s", sourceFolder, "-t", targetFolder, "-o", "-r", "-u", remoteUser)

								Expect(output).To(SatisfyAll(
									MatchRegexp("ERROR"),
									MatchRegexp("failed to copy"),
									MatchRegexp("local parent not existing"),
								))
							})
						})
					})
				})
			})
		})

		When("node is Windows node", Label("windows-node"), func() {
			const remoteUser = "administrator"

			var ipAddress string

			BeforeEach(func() {
				Skip("copy from not implemented yet for Win nodes")

				if skipWinNodeTests {
					Skip("Windows node tests are skipped")
				}

				ipAddress = k2s.GetWindowsNode(suite.SetupInfo().Config.Nodes).IpAddress

				GinkgoWriter.Println("Using Windows node IP address <", ipAddress, ">")
			})

			It("is not implemented yet", func(ctx context.Context) {
				output := suite.K2sCli().RunWithExitCode(ctx, k2s.ExitCodeFailure, "node", "copy", "--ip-addr", ipAddress, "-s", "", "-t", "", "-o", "--reverse", "-u", remoteUser)

				Expect(output).To(SatisfyAll(
					MatchRegexp("ERROR"),
					MatchRegexp("reverse copy not implemented yet"),
				))
			})
		})
	})
})

func (ssh sshExecutor) exec(ctx context.Context, remoteCmd string) string {
	return ssh.execFunc(ctx, "ssh.exe", "-n", "-o", "StrictHostKeyChecking=no", "-i", ssh.keyPath, ssh.remoteUser+"@"+ssh.ipAddress, remoteCmd)
}
