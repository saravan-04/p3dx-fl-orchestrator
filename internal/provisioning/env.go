package provisioning

import (
	"os"
	"path/filepath"
	"strings"
)

// mergeEnv starts from the current process environment and applies
// overrides on top (a duplicate key is fully replaced, not appended),
// returning a deduplicated KEY=VALUE slice suitable for exec.Cmd.Env.
func mergeEnv(overrides map[string]string) []string {
	merged := make(map[string]string)
	for _, kv := range os.Environ() {
		if i := strings.IndexByte(kv, '='); i >= 0 {
			merged[kv[:i]] = kv[i+1:]
		}
	}
	for k, v := range overrides {
		merged[k] = v
	}
	out := make([]string, 0, len(merged))
	for k, v := range merged {
		out = append(out, k+"="+v)
	}
	return out
}

// baseEnvOverrides prepends ~/.local/bin to PATH — terraform is installed
// there (no sudo needed) rather than somewhere already on this process's
// PATH, so spawned commands can find it regardless of how this service was
// started. Mirrors vmAutoProvision.service.js's BASE_ENV.
func baseEnvOverrides() map[string]string {
	home, _ := os.UserHomeDir()
	extraPath := filepath.Join(home, ".local", "bin")
	return map[string]string{
		"PATH": extraPath + string(os.PathListSeparator) + os.Getenv("PATH"),
	}
}
