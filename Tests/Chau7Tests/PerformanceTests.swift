import XCTest
@testable import Chau7Core

// MARK: - Performance Tests

/// Performance benchmarks for critical operations
final class PerformanceTests: XCTestCase {

    // MARK: - Command Detection Performance

    func testPerformance_CommandDetection_Simple() {
        let commands = [
            "claude", "codex", "gemini", "chatgpt", "copilot",
            "aider", "cursor", "ls", "cd", "git status"
        ]

        measure {
            for _ in 0..<1000 {
                for cmd in commands {
                    _ = CommandDetection.detectApp(from: cmd)
                }
            }
        }
    }

    func testPerformance_CommandDetection_Complex() {
        let commands = [
            "sudo ANTHROPIC_API_KEY=xxx claude --model opus",
            "/usr/local/bin/python3 -m codex.cli --help",
            "command time env PATH=/custom:$PATH gemini chat",
            "noglob npx @anthropic-ai/claude-code --version"
        ]

        measure {
            for _ in 0..<1000 {
                for cmd in commands {
                    _ = CommandDetection.detectApp(from: cmd)
                }
            }
        }
    }

    // MARK: - Shell Escaping Performance

    func testPerformance_ShellEscaping_Simple() {
        let args = ["hello", "world", "file.txt", "/path/to/file", "simple"]

        measure {
            for _ in 0..<10000 {
                for arg in args {
                    _ = ShellEscaping.escapeArgument(arg)
                }
            }
        }
    }

    func testPerformance_ShellEscaping_Complex() {
        let args = [
            "hello'world",
            "file with spaces.txt",
            "/path/to/file's name",
            "argument; rm -rf /",
            "$(whoami)",
            "`id`",
            "test\nwith\nnewlines"
        ]

        measure {
            for _ in 0..<10000 {
                for arg in args {
                    _ = ShellEscaping.escapeArgument(arg)
                }
            }
        }
    }

    func testPerformance_PathValidation() {
        let paths = [
            "/Users/test/file.txt",
            "./relative/path.swift",
            "../parent/file.md",
            "/var/log/system.log",
            "~/Documents/notes.txt"
        ]

        measure {
            for _ in 0..<10000 {
                for path in paths {
                    _ = ShellEscaping.isValidPath(path)
                }
            }
        }
    }

    func testPerformance_SSHValidation() {
        let options = [
            "-o StrictHostKeyChecking=no",
            "-o UserKnownHostsFile=/dev/null",
            "-o ConnectTimeout=10",
            "-o ServerAliveInterval=60",
            "-L 8080:localhost:80"
        ]

        measure {
            for _ in 0..<5000 {
                for opt in options {
                    _ = ShellEscaping.validateSSHOptions(opt)
                }
            }
        }
    }

    // MARK: - Snippet Parsing Performance

    func testPerformance_SnippetExpansion_Simple() {
        let templates = [
            "git commit -m \"${1:message}\"",
            "cd ${env:HOME}/projects",
            "docker run -it ${1:image}:${2:tag}",
            "curl -X ${1:GET} ${2:url}",
            "ssh ${1:user}@${2:host}"
        ]

        measure {
            for _ in 0..<5000 {
                for template in templates {
                    _ = SnippetParsing.expandPlaceholders(in: template)
                }
            }
        }
    }

    func testPerformance_SnippetExpansion_Complex() {
        let template = """
        #!/bin/bash
        # ${1:Script Name}
        # Author: ${env:USER}
        # Date: ${env:DATE}

        set -euo pipefail

        function ${2:main}() {
            local arg1="${3:value1}"
            local arg2="${4:value2}"

            echo "Running with $arg1 and $arg2"
            ${5:# TODO: implement}
        }

        ${2:main} "$@"
        """

        measure {
            for _ in 0..<2000 {
                _ = SnippetParsing.expandPlaceholders(in: template)
            }
        }
    }

    func testPerformance_EnvironmentTokens() {
        let template = "export PATH=${env:HOME}/bin:${env:PATH}; cd ${env:PWD}; echo ${env:USER}@${env:HOSTNAME}"

        measure {
            for _ in 0..<5000 {
                _ = SnippetParsing.replaceEnvTokens(in: template)
            }
        }
    }

    // MARK: - Color Parsing Performance

    func testPerformance_ColorParsing_Hex() {
        let hexColors = [
            "#FF0000", "#00FF00", "#0000FF", "#FFFFFF", "#000000",
            "#1E1E1E", "#282A36", "#2E3440", "#FAF8F5", "#839496"
        ]

        measure {
            for _ in 0..<10000 {
                for hex in hexColors {
                    _ = ColorParsing.parseHex(hex)
                }
            }
        }
    }

    func testPerformance_ColorBrightness() {
        let colors: [ColorParsing.RGB] = [
            ColorParsing.RGB(r: 255, g: 0, b: 0),
            ColorParsing.RGB(r: 0, g: 255, b: 0),
            ColorParsing.RGB(r: 0, g: 0, b: 255),
            ColorParsing.RGB(r: 128, g: 128, b: 128),
            ColorParsing.RGB(r: 255, g: 255, b: 255),
            ColorParsing.RGB(r: 0, g: 0, b: 0),
            ColorParsing.RGB(r: 30, g: 30, b: 30),
            ColorParsing.RGB(r: 40, g: 42, b: 54),
            ColorParsing.RGB(r: 46, g: 52, b: 64)
        ]

        measure {
            for _ in 0..<10000 {
                for color in colors {
                    _ = ColorParsing.adjustBrightness(color, factor: 1.2)
                }
            }
        }
    }

    // MARK: - Tokenization Performance

    func testPerformance_Tokenization_Simple() {
        let commands = [
            "ls -la",
            "git status",
            "cd ~/projects",
            "npm install",
            "swift build"
        ]

        measure {
            for _ in 0..<5000 {
                for cmd in commands {
                    _ = CommandDetection.tokenize(cmd)
                }
            }
        }
    }

    func testPerformance_Tokenization_Complex() {
        let commands = [
            "echo 'hello world' | grep 'hello'",
            "VAR=\"value with spaces\" command --flag",
            "cmd \"nested 'quotes' here\" arg",
            "escaped\\ spaces\\ in\\ path",
            "LANG=C LC_ALL=C sort -u file.txt"
        ]

        measure {
            for _ in 0..<5000 {
                for cmd in commands {
                    _ = CommandDetection.tokenize(cmd)
                }
            }
        }
    }

    // MARK: - CSV Parsing Performance

    func testPerformance_CSVParsing() {
        let csvStrings = [
            "one,two,three,four,five",
            "a, b, c, d, e, f, g, h",
            "value1,value2,value3",
            "item-a, item-b, item-c, item-d",
            "1,2,3,4,5,6,7,8,9,10"
        ]

        measure {
            for _ in 0..<10000 {
                for csv in csvStrings {
                    _ = SnippetParsing.parseCSV(csv)
                }
            }
        }
    }
}
