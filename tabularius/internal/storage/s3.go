// Package storage keeps the S3 file storage of PocketBase usable: the
// connection can come from the environment (S3_*) instead of the admin
// UI, and a region that no S3 service accepts is caught before every
// upload fails on it.
//
// Background: the admin UI takes any text as region. With the label of
// the Cloudflare dashboard („Europäische Union (EU)“) R2 rejected every
// write with InvalidRegionName, PocketBase answered the app with 400 and
// no photo was ever stored.
package storage

import (
	"errors"
	"fmt"
	"log/slog"
	"net/url"
	"regexp"
	"slices"
	"strconv"
	"strings"

	"github.com/pocketbase/pocketbase/core"
)

// r2Regions are the location hints Cloudflare R2 accepts as region.
var r2Regions = []string{"auto", "wnam", "enam", "weur", "eeur", "apac", "oc"}

// regionCode is the shape of every S3 region name: lower-case words
// joined by dashes („eu-central-1“, „auto“).
var regionCode = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)

// CheckRegion reports why region is no valid region for the S3 service
// at endpoint, nil when it is.
func CheckRegion(endpoint, region string) error {
	region = strings.TrimSpace(region)
	if isR2(endpoint) {
		if slices.Contains(r2Regions, region) {
			return nil
		}
		return fmt.Errorf("S3 region %q is not valid for Cloudflare R2; use \"auto\" (or one of %s)",
			region, strings.Join(r2Regions[1:], ", "))
	}
	if !regionCode.MatchString(region) {
		return fmt.Errorf("S3 region %q is no region code (e.g. \"eu-central-1\")", region)
	}
	return nil
}

func isR2(endpoint string) bool {
	u, err := url.Parse(strings.TrimSpace(endpoint))
	if err != nil {
		return false
	}
	return strings.HasSuffix(strings.ToLower(u.Hostname()), ".r2.cloudflarestorage.com")
}

// FromEnv reads the S3 connection from S3_ENDPOINT, S3_BUCKET,
// S3_REGION (default "auto"), S3_ACCESS_KEY, S3_SECRET and
// S3_FORCE_PATH_STYLE. Without S3_ENDPOINT ok is false: the settings of
// the admin UI stay as they are.
func FromEnv(getenv func(string) string) (cfg core.S3Config, ok bool, err error) {
	get := func(k string) string { return strings.TrimSpace(getenv(k)) }
	endpoint := get("S3_ENDPOINT")
	if endpoint == "" {
		return core.S3Config{}, false, nil
	}
	cfg = core.S3Config{
		Enabled:   true,
		Endpoint:  endpoint,
		Bucket:    get("S3_BUCKET"),
		Region:    get("S3_REGION"),
		AccessKey: get("S3_ACCESS_KEY"),
		Secret:    get("S3_SECRET"),
	}
	if cfg.Region == "" {
		cfg.Region = "auto"
	}
	if raw := get("S3_FORCE_PATH_STYLE"); raw != "" {
		v, perr := strconv.ParseBool(raw)
		if perr != nil {
			return core.S3Config{}, true, fmt.Errorf("S3_FORCE_PATH_STYLE: %w", perr)
		}
		cfg.ForcePathStyle = v
	}
	var missing []string
	for _, f := range []struct{ key, value string }{
		{"S3_BUCKET", cfg.Bucket}, {"S3_ACCESS_KEY", cfg.AccessKey}, {"S3_SECRET", cfg.Secret},
	} {
		if f.value == "" {
			missing = append(missing, f.key)
		}
	}
	if len(missing) > 0 {
		return core.S3Config{}, true, fmt.Errorf("S3_ENDPOINT is set, but %s missing", strings.Join(missing, ", "))
	}
	if err := CheckRegion(cfg.Endpoint, cfg.Region); err != nil {
		return core.S3Config{}, true, fmt.Errorf("S3_REGION: %w", err)
	}
	return cfg, true, nil
}

// errManagedByEnv rejects S3 changes in the admin UI while the
// environment sets them; they would be gone after the next start.
var errManagedByEnv = errors.New("the S3 file storage is set by the S3_* environment variables of the container")

// Register applies the S3 connection from the environment on start and
// checks the settings: on start (error log) and when the admin UI saves
// them (rejected with the reason).
func Register(app core.App, getenv func(string) string, logger *slog.Logger) {
	cfg, fromEnv, envErr := FromEnv(getenv)

	app.OnBootstrap().BindFunc(func(e *core.BootstrapEvent) error {
		if err := e.Next(); err != nil {
			return err
		}
		switch {
		case envErr != nil:
			// Starting anyway: everything but file uploads works.
			logger.Error("storage: S3 environment not applied", slog.Any("err", envErr))
		case fromEnv:
			if err := apply(e.App, cfg); err != nil {
				logger.Error("storage: S3 settings not saved", slog.Any("err", err))
			} else {
				logger.Info("storage: S3 settings from environment", slog.String("region", cfg.Region))
			}
		default:
			if err := checkSettings(e.App.Settings().S3); err != nil {
				logger.Error("storage: S3 settings unusable, file uploads will fail", slog.Any("err", err))
			}
		}
		return nil
	})

	app.OnSettingsUpdateRequest().BindFunc(func(e *core.SettingsUpdateRequestEvent) error {
		if fromEnv && envErr == nil && e.NewSettings.S3 != e.OldSettings.S3 {
			return e.BadRequestError(errManagedByEnv.Error(), nil)
		}
		if err := checkSettings(e.NewSettings.S3); err != nil {
			return e.BadRequestError(err.Error(), nil)
		}
		return e.Next()
	})
}

// checkSettings checks an enabled S3 storage; a disabled one is fine.
func checkSettings(s3 core.S3Config) error {
	if !s3.Enabled {
		return nil
	}
	return CheckRegion(s3.Endpoint, s3.Region)
}

// apply stores cfg as the S3 file storage, unless it is set already.
func apply(app core.App, cfg core.S3Config) error {
	settings := app.Settings()
	if settings.S3 == cfg {
		return nil
	}
	settings.S3 = cfg
	return app.Save(settings)
}
