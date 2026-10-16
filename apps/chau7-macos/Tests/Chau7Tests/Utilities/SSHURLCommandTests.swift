import XCTest
import Chau7Core

final class SSHURLCommandTests: XCTestCase {
    func testExternalDestinationsCannotBecomeSSHOptions() {
        for target in [
            "",
            "-oProxyCommand=touch${IFS}/tmp/unwanted",
            "-F/etc/ssh/config",
            " host",
            "host\ncommand",
            "host\rcommand",
            "host\targ",
            "host\0arg"
        ] {
            XCTAssertNil(ShellEscaping.sshCommand(forURLTarget: target), target)
        }
    }

    func testExplicitPortsUseSSHURIForm() {
        XCTAssertEqual(
            ShellEscaping.sshCommand(forURLTarget: "alice@host:2222"),
            "ssh -- 'ssh://alice@host:2222'"
        )
        XCTAssertEqual(
            ShellEscaping.sshCommand(forURLTarget: "alice@[::1]:2222"),
            "ssh -- 'ssh://alice@[::1]:2222'"
        )
        for target in ["host:0", "host:65536", "host:abc", "host:", "alice@-oProxyCommand=x"] {
            XCTAssertNil(ShellEscaping.sshCommand(forURLTarget: target), target)
        }
    }

    func testNormalDestinationsAreQuotedAfterEndOfOptions() {
        XCTAssertEqual(
            ShellEscaping.sshCommand(forURLTarget: "alice@example.com"),
            "ssh -- 'alice@example.com'"
        )
        XCTAssertEqual(
            ShellEscaping.sshCommand(forURLTarget: "my-ssh-alias"),
            "ssh -- 'my-ssh-alias'"
        )
        XCTAssertEqual(
            ShellEscaping.sshCommand(forURLTarget: "alice@2001:db8::1"),
            "ssh -- 'alice@2001:db8::1'"
        )
        XCTAssertEqual(
            ShellEscaping.sshCommand(forURLTarget: "o'brien@host"),
            "ssh -- 'o'\\''brien@host'"
        )
    }
}
