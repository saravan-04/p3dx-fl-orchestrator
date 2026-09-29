// Package config loads runtime configuration for the fl-orchestrator service
// from environment variables (and the service's own .env, loaded with
// override semantics — see LoadEnv), mirroring p3dx_gov_layer's config
// package.
package config

import (
	"os"
	"path/filepath"

	"github.com/joho/godotenv"
)

// Config holds every tunable used by the service.
type Config struct {
	Port    string // PORT (default 3002)
	CORSRaw string // CORS_ORIGINS

	KeycloakBaseURL string // KEYCLOAK_BASE_URL
	KeycloakRealm   string // KEYCLOAK_REALM

	// InternalServiceKey guards POST /p3dx/internal/register-expected-providers
	// (X-Internal-Key header). An empty value disables the check, same
	// "empty disables it" convention as gov_layer's VM_REGISTRY_TOKEN.
	InternalServiceKey string

	// GHCR pull creds, forwarded to terraform as TF_VAR_ghcr_namespace /
	// TF_VAR_ghcr_token (see internal/provisioning) — lets provisioned VMs
	// `docker login ghcr.io` instead of building from source.
	GHCRNamespace string
	GHCRPullToken string

	// TerraformDir is the participant-vm terraform root, local to this
	// service now (moved in from the workspace-root terraform/ directory).
	TerraformDir string

	// ServiceRoot is this service's own directory (p3dx-fl-orchestrator/),
	// used to resolve TerraformDir, the provisioning log dir, and the
	// terraform plugin cache — all local to this service, not the outer
	// workspace.
	ServiceRoot string
}

// LoadEnv loads the service's own .env with OVERRIDE semantics, matching
// gov_layer's config.LoadEnv. A missing .env is non-fatal.
func LoadEnv() {
	_ = godotenv.Overload(".env")
}

// Load reads configuration from the environment.
func Load() *Config {
	root := serviceRoot()

	return &Config{
		Port:    getEnv("PORT", "3002"),
		CORSRaw: os.Getenv("CORS_ORIGINS"),

		KeycloakBaseURL: os.Getenv("KEYCLOAK_BASE_URL"),
		KeycloakRealm:   os.Getenv("KEYCLOAK_REALM"),

		InternalServiceKey: os.Getenv("INTERNAL_SERVICE_KEY"),

		GHCRNamespace: os.Getenv("GHCR_NAMESPACE"),
		GHCRPullToken: os.Getenv("GHCR_PULL_TOKEN"),

		TerraformDir: getEnv("TERRAFORM_DIR", filepath.Join(root, "terraform", "participant-vm")),
		ServiceRoot:  root,
	}
}

func getEnv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}

// serviceRoot returns this process's working directory (start-all.sh launches
// it from p3dx-fl-orchestrator/, same as every other service here).
func serviceRoot() string {
	cwd, err := os.Getwd()
	if err != nil {
		return "."
	}
	abs, err := filepath.Abs(cwd)
	if err != nil {
		return cwd
	}
	return abs
}
