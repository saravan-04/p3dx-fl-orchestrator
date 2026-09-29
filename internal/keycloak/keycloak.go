// Package keycloak verifies incoming Keycloak-issued JWTs against the realm's
// JWKS. Ported from p3dx_gov_layer/internal/services/keycloak.go — same JWKS
// fetch + RS256 verification, no local caching of keys (each call refetches,
// matching that implementation).
package keycloak

import (
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"math/big"
	"net/http"
	"strings"

	"github.com/golang-jwt/jwt/v5"
)

type jwks struct {
	Keys []jwk `json:"keys"`
}

type jwk struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	N   string `json:"n"`
	E   string `json:"e"`
}

// FetchJWKS fetches the JWKS for the given Keycloak base URL + realm and
// returns RSA public keys indexed by kid.
func FetchJWKS(baseURL, realm string) (map[string]*rsa.PublicKey, error) {
	base := strings.TrimRight(baseURL, "/")
	if base == "" || realm == "" {
		return nil, fmt.Errorf("KEYCLOAK_BASE_URL/KEYCLOAK_REALM not configured")
	}
	jwksURL := base + "/realms/" + realm + "/protocol/openid-connect/certs"

	resp, err := http.Get(jwksURL)
	if err != nil {
		return nil, fmt.Errorf("fetch JWKS: %w", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("JWKS returned status %d", resp.StatusCode)
	}
	var parsed jwks
	if err := json.NewDecoder(resp.Body).Decode(&parsed); err != nil {
		return nil, fmt.Errorf("decode JWKS: %w", err)
	}
	keys := make(map[string]*rsa.PublicKey)
	for _, k := range parsed.Keys {
		if k.Kty != "RSA" || k.N == "" || k.E == "" {
			continue
		}
		pub, err := jwkToRSAPublicKey(k)
		if err != nil {
			continue
		}
		kid := k.Kid
		if kid == "" {
			kid = "default"
		}
		keys[kid] = pub
	}
	if len(keys) == 0 {
		return nil, fmt.Errorf("no RSA keys in JWKS")
	}
	return keys, nil
}

func jwkToRSAPublicKey(k jwk) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(k.N)
	if err != nil {
		return nil, err
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(k.E)
	if err != nil {
		return nil, err
	}
	n := new(big.Int).SetBytes(nBytes)
	var e int
	for _, b := range eBytes {
		e = e<<8 + int(b)
	}
	if e == 0 {
		e = 65537
	}
	return &rsa.PublicKey{N: n, E: e}, nil
}

// ValidateAccessToken verifies a Keycloak-issued JWT against the realm JWKS.
func ValidateAccessToken(baseURL, realm, tokenStr string) (*jwt.Token, error) {
	if tokenStr == "" {
		return nil, fmt.Errorf("empty token")
	}
	keysByKID, err := FetchJWKS(baseURL, realm)
	if err != nil {
		return nil, err
	}
	parser := jwt.NewParser(jwt.WithValidMethods([]string{"RS256"}))
	return parser.Parse(tokenStr, func(t *jwt.Token) (any, error) {
		kid, _ := t.Header["kid"].(string)
		if kid == "" {
			if pub, ok := keysByKID["default"]; ok {
				return pub, nil
			}
			return nil, fmt.Errorf("token header missing kid")
		}
		pub, ok := keysByKID[kid]
		if !ok {
			return nil, fmt.Errorf("kid %q not found in Keycloak JWKS", kid)
		}
		return pub, nil
	})
}

// PreferredUsername extracts the "preferred_username" claim, mirroring
// req.user?.preferred_username in the Node services this replaces.
func PreferredUsername(t *jwt.Token) string {
	claims, ok := t.Claims.(jwt.MapClaims)
	if !ok {
		return ""
	}
	username, _ := claims["preferred_username"].(string)
	return username
}
