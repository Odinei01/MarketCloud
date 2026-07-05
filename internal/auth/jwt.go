package auth

import (
	"crypto/rand"
	"encoding/hex"
	"errors"
	"fmt"
	"time"

	"github.com/golang-jwt/jwt/v5"
	"github.com/google/uuid"
	"golang.org/x/crypto/bcrypt"
)

type Claims struct {
	TenantID  uuid.UUID `json:"tid"`
	UserID    uuid.UUID `json:"uid"`
	Role      string    `json:"role"`
	StoreIDs  []string  `json:"stores,omitempty"`
	jwt.RegisteredClaims
}

type TokenPair struct {
	AccessToken  string `json:"access_token"`
	RefreshToken string `json:"refresh_token"`
	ExpiresIn    int64  `json:"expires_in"`
}

const accessTTL = 15 * time.Minute
const refreshTTL = 7 * 24 * time.Hour

func IssueTokenPair(secret string, tenantID, userID uuid.UUID, role string, storeIDs []string) (TokenPair, error) {
	now := time.Now()
	claims := Claims{
		TenantID: tenantID,
		UserID:   userID,
		Role:     role,
		StoreIDs: storeIDs,
		RegisteredClaims: jwt.RegisteredClaims{
			Subject:   userID.String(),
			IssuedAt:  jwt.NewNumericDate(now),
			ExpiresAt: jwt.NewNumericDate(now.Add(accessTTL)),
		},
	}
	accessToken, err := jwt.NewWithClaims(jwt.SigningMethodHS256, claims).SignedString([]byte(secret))
	if err != nil {
		return TokenPair{}, fmt.Errorf("sign access token: %w", err)
	}

	rawRefresh := make([]byte, 32)
	if _, err := rand.Read(rawRefresh); err != nil {
		return TokenPair{}, fmt.Errorf("generate refresh token: %w", err)
	}
	refreshToken := hex.EncodeToString(rawRefresh)

	return TokenPair{
		AccessToken:  accessToken,
		RefreshToken: refreshToken,
		ExpiresIn:    int64(accessTTL.Seconds()),
	}, nil
}

func ParseClaims(secret, tokenStr string) (*Claims, error) {
	token, err := jwt.ParseWithClaims(tokenStr, &Claims{}, func(t *jwt.Token) (interface{}, error) {
		if _, ok := t.Method.(*jwt.SigningMethodHMAC); !ok {
			return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
		}
		return []byte(secret), nil
	})
	if err != nil {
		return nil, err
	}
	claims, ok := token.Claims.(*Claims)
	if !ok || !token.Valid {
		return nil, errors.New("invalid token")
	}
	return claims, nil
}

func HashPassword(password string) (string, error) {
	h, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
	return string(h), err
}

func CheckPassword(hash, password string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(password)) == nil
}

func HashToken(token string) (string, error) {
	h, err := bcrypt.GenerateFromPassword([]byte(token), bcrypt.MinCost)
	return string(h), err
}

func CheckToken(hash, token string) bool {
	return bcrypt.CompareHashAndPassword([]byte(hash), []byte(token)) == nil
}

func GenerateAPIKey() string {
	b := make([]byte, 24)
	rand.Read(b)
	return "mc_" + hex.EncodeToString(b)
}
