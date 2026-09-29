package provisioning

import (
	"bufio"
	"fmt"
	"os/exec"
	"strings"
	"sync"
)

// runCommand runs one command to completion, streaming each stdout/stderr
// line to onLine as it arrives (trimmed, non-empty lines only) while also
// buffering both streams in full for error reporting — mirroring
// vmAutoProvision.service.js's runCommand.
func runCommand(command string, args []string, dir string, env []string, onLine func(line string)) (stdout string, stderr string, err error) {
	cmd := exec.Command(command, args...)
	cmd.Dir = dir
	cmd.Env = env

	stdoutPipe, err := cmd.StdoutPipe()
	if err != nil {
		return "", "", err
	}
	stderrPipe, err := cmd.StderrPipe()
	if err != nil {
		return "", "", err
	}

	if err := cmd.Start(); err != nil {
		return "", "", err
	}

	var stdoutBuf, stderrBuf strings.Builder
	var wg sync.WaitGroup
	wg.Add(2)

	scan := func(r *bufio.Scanner, buf *strings.Builder) {
		defer wg.Done()
		for r.Scan() {
			line := r.Text()
			buf.WriteString(line)
			buf.WriteByte('\n')
			trimmed := strings.TrimSpace(line)
			if trimmed != "" && onLine != nil {
				onLine(trimmed)
			}
		}
	}

	stdoutScanner := bufio.NewScanner(stdoutPipe)
	stdoutScanner.Buffer(make([]byte, 64*1024), 8*1024*1024)
	stderrScanner := bufio.NewScanner(stderrPipe)
	stderrScanner.Buffer(make([]byte, 64*1024), 8*1024*1024)

	go scan(stdoutScanner, &stdoutBuf)
	go scan(stderrScanner, &stderrBuf)
	wg.Wait()

	waitErr := cmd.Wait()
	stdout = stdoutBuf.String()
	stderr = stderrBuf.String()

	if waitErr != nil {
		// stderr alone is usually just the tool's own generic summary; the
		// actual cause a provisioner script printed goes to stdout. Combine
		// both so that detail isn't silently dropped from the error.
		combined := strings.TrimSpace(stdout + "\n" + stderr)
		if len(combined) > 2000 {
			combined = combined[len(combined)-2000:]
		}
		return stdout, stderr, fmt.Errorf("%s %s failed: %w: %s", command, strings.Join(args, " "), waitErr, combined)
	}
	return stdout, stderr, nil
}
