package storage

import (
	"strings"
	"testing"
)

const r2Endpoint = "https://account.r2.cloudflarestorage.com"

func env(vars map[string]string) func(string) string {
	return func(k string) string { return vars[k] }
}

// The label of the Cloudflare dashboard is no region code; R2 rejects
// every write with it (InvalidRegionName).
func TestCheckRegion_R2RejectsDashboardLabel(t *testing.T) {
	err := CheckRegion(r2Endpoint, "Europäische Union (EU)")
	if err == nil {
		t.Fatal("dashboard label must be rejected")
	}
	if !strings.Contains(err.Error(), "auto") {
		t.Errorf("message should name the valid value: %v", err)
	}
}

func TestCheckRegion_R2AcceptsItsCodes(t *testing.T) {
	// us-east-1 is R2's alias for auto, for tools that insist on a region.
	for _, r := range []string{"auto", "weur", "eeur", "wnam", "enam", "apac", "oc", "us-east-1"} {
		if err := CheckRegion(r2Endpoint, r); err != nil {
			t.Errorf("%q: %v", r, err)
		}
	}
}

// R2 knows only its own short codes, not AWS names.
func TestCheckRegion_R2RejectsAWSName(t *testing.T) {
	if CheckRegion(r2Endpoint, "eu-central-1") == nil {
		t.Error("an AWS region is not valid on R2")
	}
}

// PocketBase also takes an endpoint without scheme.
func TestCheckRegion_R2EndpointWithoutScheme(t *testing.T) {
	if CheckRegion("account.r2.cloudflarestorage.com", "eu-central-1") == nil {
		t.Error("R2 without scheme must still be checked as R2")
	}
	if err := CheckRegion("account.r2.cloudflarestorage.com", "auto"); err != nil {
		t.Error(err)
	}
}

// PocketBase signs with the region as stored; surrounding blanks break
// every upload.
func TestCheckRegion_RejectsSurroundingWhitespace(t *testing.T) {
	for _, r := range []string{" auto", "auto ", " eu-central-1 "} {
		if CheckRegion(r2Endpoint, r) == nil || CheckRegion("https://s3.example", r) == nil {
			t.Errorf("%q must be rejected", r)
		}
	}
}

func TestCheckRegion_OtherProvidersNeedACode(t *testing.T) {
	if err := CheckRegion("https://s3.eu-central-1.amazonaws.com", "eu-central-1"); err != nil {
		t.Errorf("AWS code: %v", err)
	}
	if err := CheckRegion("https://minio.example:9000", "us-east-1"); err != nil {
		t.Errorf("MinIO code: %v", err)
	}
	for _, bad := range []string{"", "  ", "EU Central", "Frankfurt (EU)"} {
		if CheckRegion("https://s3.example", bad) == nil {
			t.Errorf("%q must be rejected", bad)
		}
	}
}

func TestFromEnv_UnsetLeavesSettingsAlone(t *testing.T) {
	_, ok, err := FromEnv(env(nil))
	if ok || err != nil {
		t.Fatalf("without S3_ENDPOINT nothing is configured: ok=%v err=%v", ok, err)
	}
}

func TestFromEnv_RegionDefaultsToAuto(t *testing.T) {
	cfg, ok, err := FromEnv(env(map[string]string{
		"S3_ENDPOINT": r2Endpoint, "S3_BUCKET": "photos",
		"S3_ACCESS_KEY": "key", "S3_SECRET": "secret",
	}))
	if err != nil || !ok {
		t.Fatalf("ok=%v err=%v", ok, err)
	}
	if !cfg.Enabled || cfg.Region != "auto" || cfg.Bucket != "photos" || cfg.Endpoint != r2Endpoint ||
		cfg.AccessKey != "key" || cfg.Secret != "secret" || cfg.ForcePathStyle {
		t.Errorf("unexpected config: %+v", cfg)
	}
}

func TestFromEnv_ForcePathStyle(t *testing.T) {
	cfg, _, err := FromEnv(env(map[string]string{
		"S3_ENDPOINT": "https://minio.example:9000", "S3_BUCKET": "b", "S3_REGION": "us-east-1",
		"S3_ACCESS_KEY": "k", "S3_SECRET": "s", "S3_FORCE_PATH_STYLE": "true",
	}))
	if err != nil || !cfg.ForcePathStyle {
		t.Errorf("force path style not set: %+v %v", cfg, err)
	}
}

func TestFromEnv_MissingOrInvalidValuesFail(t *testing.T) {
	base := map[string]string{
		"S3_ENDPOINT": r2Endpoint, "S3_BUCKET": "b", "S3_ACCESS_KEY": "k", "S3_SECRET": "s",
	}
	for _, key := range []string{"S3_BUCKET", "S3_ACCESS_KEY", "S3_SECRET"} {
		vars := map[string]string{}
		for k, v := range base {
			vars[k] = v
		}
		delete(vars, key)
		if _, _, err := FromEnv(env(vars)); err == nil || !strings.Contains(err.Error(), key) {
			t.Errorf("missing %s: %v", key, err)
		}
	}
	vars := map[string]string{"S3_REGION": "Europäische Union (EU)"}
	for k, v := range base {
		vars[k] = v
	}
	if _, _, err := FromEnv(env(vars)); err == nil {
		t.Error("invalid region must fail")
	}
}
